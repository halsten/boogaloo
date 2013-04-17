{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
module Language.Boogie.Z3.GenMonad where

import           Control.Applicative
import           Control.Lens ((%=), view, _1, _2, _3, uses, makeLenses)
import           Control.Monad.Trans.State
import           Control.Monad.Trans

import           Data.List (intercalate)
import           Data.Generics
import           Data.Maybe
import qualified Data.Map as Map
import           Data.Map (Map)
import qualified Data.Set as Set
import           Data.Set (Set)

import           Z3.Monad

import           Language.Boogie.AST
import           Language.Boogie.Heap
import           Language.Boogie.PrettyAST ()

data TaggedRef 
    = LogicRef Type Ref 
    | MapRef Type Ref
      deriving (Eq, Ord, Show, Data, Typeable)

data Custom = Custom Type Int
            deriving (Eq, Ord, Show)


data Z3Env = Z3Env
    { _ctorMap :: 
          Map [Type] 
                 (Sort, FuncDecl, [FuncDecl]) -- ^ Maps a list of types to a
                                              -- a tuple of them, and the
                                              -- associated constructor.
    , _sortMap :: Map Type Sort               -- ^ Maps types to sorts
    , _refMap  :: Map TaggedRef AST           -- ^ Maps references to their
                                              -- Z3 AST node.
    , _customVals :: Map Int AST              -- ^ Map custom value tags to
                                              -- their AST.
    , _customMap :: 
        Map (Id,[Type])
                (Sort, FuncDecl, FuncDecl)    -- ^ Map from identifier and
                                              -- type arguments to a 
                                              -- an uninterpreted type
    , _oldCustoms :: Set Custom               -- ^ A set of custom
                                              -- values that were sent
                                              -- into Z3. These will be used to
                                              -- determine if new values were
                                              -- generated or not.
    , _newCustoms :: Set Custom               -- ^ A set of the new custom
                                              -- values that are generated
                                              -- by Z3, not given in the
                                              -- constraints.
    }

makeLenses ''Z3Env

instance MonadZ3 Z3Gen where
    getSolver = lift getSolver
    getContext = lift getContext

type Z3Gen = StateT Z3Env Z3

emptyEnv :: Z3Env
emptyEnv = Z3Env Map.empty Map.empty Map.empty Map.empty Map.empty
                 Set.empty Set.empty

evalZ3Gen :: Z3Gen a -> IO a
evalZ3Gen act = evalZ3 $ evalStateT act emptyEnv

debug :: MonadIO m => String -> m ()
debug = const (return ()) -- liftIO . putStrLn

lookup' :: Ord k => String -> k -> Map k a -> a
lookup' errMsg key m =
  case Map.lookup key m of
    Just a -> a
    Nothing -> error errMsg

justElse :: Maybe a -> a -> a
justElse = flip fromMaybe

justElseM :: Monad m => Maybe a -> m a -> m a
justElseM mb v = maybe v return mb

lookupSort :: Type -> Z3Gen Sort
lookupSort ttype =
    do sortMb <- uses sortMap (Map.lookup ttype)
       justElseM sortMb $
         do s <- typeToSort ttype
            sortMap %= Map.insert ttype s
            return s
    where
      -- | Construct a type map.
      typeToSort :: Type -> Z3Gen Sort
      typeToSort t =
          case t of
            IntType  -> mkIntSort
            BoolType -> mkBoolSort
            MapType _ argTypes resType ->
                do tupleArgSort <- lookupTupleSort argTypes
                   resSort <- lookupSort resType
                   mkArraySort tupleArgSort resSort
            IdType ident types -> view _1 <$> lookupCustomType ident types

lookupCustomType :: Id -> [Type] -> Z3Gen (Sort, FuncDecl, FuncDecl)
lookupCustomType ident types =
    do custMb <- uses customMap (Map.lookup (ident, types))
       justElseM custMb $
         do let str = customSymbol ident types
            sym <- mkStringSymbol str
            projSym <- mkStringSymbol (str ++ "_proj")
            intSort <- lookupSort IntType
            (sort, ctor, [proj]) <- mkTupleSort sym [(projSym, intSort)]
            let res = (sort, ctor, proj)
            customMap %= Map.insert (ident, types) res
            return res

lookupCustomCtor :: Id -> [Type] -> Z3Gen FuncDecl
lookupCustomCtor ident types =
    view _2 <$> lookupCustomType ident types

lookupCustomProj :: Id -> [Type] -> Z3Gen FuncDecl
lookupCustomProj ident types =
    view _3 <$> lookupCustomType ident types

lookupTupleSort :: [Type] -> Z3Gen Sort
lookupTupleSort types = ( \ (a,_,_) -> a) <$> lookupCtor types

-- | Construct a tuple from the given arguments
lookupCtor :: [Type] -> Z3Gen (Sort, FuncDecl, [FuncDecl])
lookupCtor types =
    do sortMb <- uses ctorMap (Map.lookup types)
       justElseM sortMb $
         do sorts   <- mapM lookupSort types
            let tupStr = tupleSymbol types
            argSyms <- mapM (mkStringSymbol . (tupStr ++) . show) 
                             [1 .. length types]
            sym     <- mkStringSymbol tupStr
            tupRes  <- mkTupleSort sym (zip argSyms sorts)
            ctorMap %= Map.insert types tupRes
            return tupRes

-- | Type name for the symbol for the sort
tupleSymbol :: [Type] -> String
tupleSymbol ts = intercalate "_" (map typeString ts) ++ "SYMBOL"

-- | Type name for the symbol for the sort
customSymbol :: Id -> [Type] -> String
customSymbol ident ts = intercalate "_" (ident : map typeString ts) ++ "_CUSTOM"


-- | Symbol name for a type
typeString :: Type -> String
typeString t =
   case t of
     IntType -> "int"
     BoolType -> "bool"
     MapType _ args res -> 
         concat ["(", tupleSymbol args, ")->", typeString res]
     _ -> error $ "typeString: no string for " ++ show t