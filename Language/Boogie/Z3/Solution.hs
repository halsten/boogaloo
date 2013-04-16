{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE BangPatterns #-}
module Language.Boogie.Z3.Solution 
    ( solveConstr
    , (!)
    , Solution(..)
    , extract
    ) where

import           Control.Applicative
import           Control.Lens ((%=), _1, _2, over, uses)
import           Control.Monad

import           Data.List (intercalate)
import qualified Data.Set as Set
import           Data.Set (Set)
import qualified Data.Map as Map
import           Data.Map (Map)

import           Z3.Monad

import           Language.Boogie.AST
import           Language.Boogie.Heap
import           Language.Boogie.Position
import           Language.Boogie.PrettyAST ()
import           Language.Boogie.Z3.Eval
import           Language.Boogie.Z3.GenMonad


-- | Update the state's reference map with the references in the
-- supplied expressions. This requires that the sorts already be
-- in place in the state.
updateRefMap :: [Expression] -> Z3Gen ()
updateRefMap = mapM_ addRefs
    where
      addRefs :: Expression -> Z3Gen ()
      addRefs e =
          do let rs = refs e
             pairs <- mapM (\r -> (r,) <$> declareRef r) (Set.toList rs)
             let updMap = Map.fromList pairs
             refMap %= Map.union updMap

      -- | Get the values from a single expression.
      refs :: Expression -> Set TaggedRef
      refs expr =
          case node expr of
            Literal v                -> valueRef v
            LogicalVar t ref         -> Set.singleton (LogicRef t ref)
            MapSelection e es        -> refUnion (e:es)
            MapUpdate e1 es e2       -> refUnion (e1:e2:es)
            Old e                    -> refs e
            IfExpr c e1 e2           -> refUnion [c,e1,e2]
            UnaryExpression _ e      -> refs e
            BinaryExpression _ e1 e2 -> refUnion [e1, e2]
            Quantified _ _ _ e       -> refs e
            e -> error $ "solveConstr.refs: " ++ show e

      -- | Get the refs of a list of expressions
      refUnion :: [Expression] -> Set TaggedRef
      refUnion = Set.unions . map refs

      -- | Get the value from a ref
      valueRef :: Value -> Set TaggedRef
      valueRef v =
          case v of
            Reference t r   -> Set.singleton (MapRef t r)
            MapValue _ repr -> Set.unions . map go . Map.toList $ repr
                where
                  go (vals, val) = Set.unions (map valueRef (val:vals))
            _ -> Set.empty

      refStr :: TaggedRef -> String
      refStr (LogicRef _ r) = "logical_" ++ show r
      refStr (MapRef t r)   = intercalate "_" ["map", show r, typeString t]
                              -- Z3 doesn't have generics, so we incorporate
                              -- the type into the name of the symbol
                              -- to avoid this name clash.

      refType :: TaggedRef -> Type
      refType (LogicRef t _) = t
      refType (MapRef t _)   = t

      declareRef :: TaggedRef -> Z3Gen AST
      declareRef tRef =
          do symbol <- mkStringSymbol (refStr tRef)
             sort   <- lookupSort (refType tRef)
             mkConst symbol sort

data MapWithElse = MapWithElse
    { _mapPart :: MapRepr
    , _elsepart :: Value
    } deriving Show

-- instance Show MapWithElse where
--   show (MapWithElse m v) = show (pretty m)

(!) :: MapWithElse -> [Value] -> Value
(!) (MapWithElse m el) i = maybe el id (Map.lookup i m)

data NewCustomVal = NewCustomVal Type Int

data Solution = Solution 
    { solnLogical :: Map Ref Value
    , solnMaps    :: Map Ref MapWithElse
    , solnCustoms :: Set NewCustomVal
    }

instance Show Solution where
  show (Solution logMap mapMap _) = 
    unlines [ "logical variables:"
            , show logMap 
            , "maps"
            , show mapMap
            ]

-- | Given a set of constraint expressions produce a mapping
-- of references to their concrete values.
--
-- The constraint expressions will have no regular variables,
-- only logical variables and map variables.

solveConstr :: [Expression] -> Z3Gen (Model, Solution)
solveConstr constrs = checkConstraints
    where
      -- | Produce a the result in the Z3 monad, to be extracted later.
      checkConstraints :: Z3Gen (Model, Solution)
      checkConstraints = 
          do updateRefMap constrs
             mapM_ (evalExpr >=> assertCnstr) constrs
             (_result, modelMb) <- getModel
             case modelMb of
               Just model -> (model,) <$> reconstruct model
               Nothing -> error "solveConstr.evalZ3: no model"


-- | Extracts a particular type from an AST node, evaluating
-- the node first.
extract :: Model -> Type -> AST -> Z3Gen Value
extract model t ast = 
    do Just ast' <- eval model ast
       case t of 
         IntType -> IntValue <$> getInt ast'
         BoolType -> 
             do bMb <- getBool ast'
                case bMb of
                  Just b -> return $ BoolValue b
                  Nothing -> error "solveConstr.reconstruct.extract: not bool"
         IdType ident types ->
             do proj <- lookupCustomProj ident types
                extr <- mkApp proj [ast']
                Just evald <- eval model extr
                int <- getInt evald
                return (CustomValue t $ fromIntegral int)
         _ ->
             error $ concat [ "solveConstr.reconstruct.extract: can't "
                            , "extract maptypes like "
                            , show t
                            ]

-- | From a model and a mapping of values to Z3 AST nodes reconstruct
-- a mapping from references to values. This extracts the appropriate
-- values from the model.
reconstruct :: Model -> Z3Gen Solution
reconstruct model =
    do (logicMap, mapMap) <- reconMaps
       customs <- customSet
       return (Solution logicMap mapMap customs)
    where
      extract' = extract model

      -- | Extract an argument to a 'select' or 'store', which is stored
      -- as a tuple. This 'untuples' the ast into a list of Boogaloo values.
      extractArg :: [Type] -> AST -> Z3Gen [Value]
      extractArg types tuple =
          do (_, _, projs) <- lookupCtor types
             debug ("extractArg start: " ++ show types)
             asts <- mapM (\ proj -> mkApp proj [tuple]) projs
             astsStr <- mapM astToString (tuple:asts)
             debug (unlines (map ("extArg: " ++) astsStr))
             zipWithM extract' types asts

      -- | Extract a Boogaloo function entry
      extractEntry :: [Type] -> Type -> [AST] -> AST -> Z3Gen ([Value], Value)
      extractEntry argTypes resType [argTuple] res =
          do debug "Entry start" 
             args <- extractArg argTypes argTuple
             debug "Extracted arg"
             res' <- extract' resType res
             debug "Extracted res"
             return (args, res')
      extractEntry _argTypes _resType _args _res =
          error "reconstruct.extractEntry: argument should be a single tuple"

      -- | Extract the new custom values from the model.
      customSet :: Z3Gen (Set NewCustomVal)
      customSet = return (Set.singleton (error "customSet"))

      -- | Reconstruct all maps
      reconMaps :: Z3Gen (Map Ref Value, Map Ref MapWithElse)
      reconMaps = 
          do refAssoc <- uses refMap Map.toList 
             foldM go (Map.empty, Map.empty) refAssoc
          where go mapTup  (tRef, ast) =
                    case tRef of
                      LogicRef _ _ ->
                          do (r, v) <- reconLogicRef tRef ast
                             return (over _1 (Map.insert r v) mapTup)
                      MapRef _ _ ->
                          do (r, v) <- reconMapWithElse tRef ast
                             return (over _2 (Map.insert r v) mapTup)

      -- | Reconstruct a map with else part from an array AST node.
      -- The argument must be a `MapRef`.
      reconMapWithElse :: TaggedRef -> AST -> Z3Gen (Ref, MapWithElse)
      reconMapWithElse (MapRef (MapType _ args res) ref) ast =
          do debug "reconMap start" 
             Just funcModel <- evalArray model ast
             !elsePart <- extract' res (interpElse funcModel)
             debug "extracted else"
             entries <- mapM (uncurry (extractEntry args res))
                             (interpMap funcModel)
             let m = Map.fromList entries
                 mapWithElse = MapWithElse m elsePart
             debug "reconMap end"
             return (ref, mapWithElse)
      reconMapWithElse _tRef _ast =
          error "reconstruct.reconMapWithElse: not a tagged map argument"

      -- | Reconstruct a ref/value pair for a logical reference.
      reconLogicRef :: TaggedRef -> AST -> Z3Gen (Ref, Value)
      reconLogicRef (LogicRef t ref) ast =
          do Just ast' <- eval model ast
             x <- extract' t ast'
             return (ref, x)
      reconLogicRef tr _ast = 
          error $ "reconLogicRef: not a logical ref" ++ show tr
