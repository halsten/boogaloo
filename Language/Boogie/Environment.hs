{-# LANGUAGE TemplateHaskell #-}

-- | Execution state for the interpreter
module Language.Boogie.Environment ( 
  MapRepr (..),
  emptyMap,
  stored,
  updateStored,
  Value (..),
  vnot,
  mapSourceValues,
  mapSource,
  mapValues,
  deepDeref,
  objectEq,
  valueDoc,
  Store,
  emptyStore,
  functionCacheName,
  userStore,
  storeDoc,
  Memory,
  memLocals,
  memGlobals,
  memOld,
  memConstants,
  memHeap,
  emptyMemory,
  visibleVariables,
  memoryDoc,  
  Environment,
  envMemory,
  envConstDefs,
  envConstConstraints,
  envFunctions,
  envProcedures,
  envTypeContext,
  envGenerator,
  envInOld,
  initEnv,
  lookupConstConstraints,
  lookupFunction,
  lookupProcedure,
  setGlobal,
  setLocal,
  setOld,
  setConst,
  addConstantDef,
  addConstantConstraint,
  addFunctionDefs,
  addProcedureDef,
  withHeap,
  functionsDoc
) where

import Language.Boogie.Util
import Language.Boogie.AST
import Language.Boogie.Heap
import Language.Boogie.Generator
import Language.Boogie.TypeChecker (Context)
import Language.Boogie.PrettyPrinter
import Data.Map (Map, (!))
import qualified Data.Map as M
import Data.Set (Set)
import qualified Data.Set as S
import Control.Lens hiding (Context, at)
import Text.PrettyPrint

{- Values -}

-- | Representation of a map value
data MapRepr = 
  Source (Map [Value] Value) |                  -- ^ Map that comes directly from a non-deterministic choice, possibly with some key-value pair defined
  Derived Ref (Map [Value] Value) (Set [Value]) -- ^ Map that is derived from another map by redefining and undefining values at some keys
  deriving (Eq, Ord)
  
-- | Representation of an empty map  
emptyMap = Source M.empty

-- | Key-value pairs stored explicitly in a map representation
stored :: MapRepr -> Map [Value] Value
stored (Source vals) = vals
stored (Derived _ override _) = override

-- | 'updateStored' @newVals repr@ : add @newVals@ to the key-value pairs stored in @repr@
updateStored :: Map [Value] Value -> MapRepr -> MapRepr
updateStored newVals (Source vals) = Source (newVals `M.union` vals)
updateStored newVals (Derived base override undef) = Derived base (newVals `M.union` override) (undef S.\\ M.keysSet newVals)
  
-- | Pretty-printed map representation  
mapReprDoc :: MapRepr -> Doc
mapReprDoc repr = case repr of
  Source vals -> brackets (commaSep (map itemDoc (M.toList vals)))
  Derived base override undef -> refDoc base <> 
    brackets (commaSep (map itemDoc (M.toList override) ++ map undefDoc (S.toList undef))) 
  where 
    itemDoc (keys, v) = commaSep (map valueDoc keys) <+> text "->" <+> valueDoc v
    undefDoc keys = commaSep (map valueDoc keys) <+> text "-> ?"

-- | Run-time value
data Value = IntValue Integer |  -- ^ Integer value
  BoolValue Bool |               -- ^ Boolean value
  CustomValue Integer |          -- ^ Value of a user-defined type (values with the same code are considered equal)
  MapValue MapRepr |             -- ^ Value of a map type: consists of an optional reference to the base map (if derived from base by updating) and key-value pairs that override base
  Reference Ref                  -- ^ Reference to a map stored in the heap
  deriving (Eq, Ord)
  
vnot (BoolValue b) = BoolValue (not b)

unMapValue (MapValue repr) = repr

-- | Pretty-printed value
valueDoc :: Value -> Doc
valueDoc (IntValue n) = integer n
valueDoc (BoolValue False) = text "false"
valueDoc (BoolValue True) = text "true"
valueDoc (MapValue repr) = mapReprDoc repr
valueDoc (CustomValue n) = text "custom_" <> integer n
valueDoc (Reference r) = refDoc r

instance Show Value where
  show v = show (valueDoc v)
  
{- Map operations -}

-- | Source reference and key-value pairs of a reference in a heap
mapSourceValues :: Heap Value -> Ref -> (Ref, (Map [Value] Value))
mapSourceValues h r = case unMapValue $ h `at` r of
  Source vals -> (r, vals)
  Derived base override undef -> let (s, v) = mapSourceValues h base
    in (s, override `M.union` (removeDomain undef v))
    
-- | First component of 'mapSourceValues'
mapSource h r = fst $ mapSourceValues h r

-- | Second component of 'mapSourceValues'
mapValues h r = snd $ mapSourceValues h r

-- | 'deepDeref' @h v@: Completely dereference value @v@ given heap @h@ (so that no references are left in @v@)
deepDeref :: Heap Value -> Value -> Value
deepDeref h v = deepDeref' v
  where
    deepDeref' (Reference r) = let (s_, vals) = mapSourceValues h r
      in MapValue . Source $ (M.map deepDeref' . M.mapKeys (map deepDeref')) vals -- Here we do not assume that keys contain no references, as this is used for error reporting
    deepDeref' (MapValue _) = internalError "Attempt to dereference a map directly"
    deepDeref' v = v

-- | 'objectEq' @h v1 v2@: is @v1@ equal to @v2@ in the Boogie semantics? Nothing if cannot be determined.
objectEq :: Heap Value -> Value -> Value -> Maybe Bool
objectEq h (Reference r1) (Reference r2) = if r1 == r2
  then Just True -- Equal references point to equal maps
  else let 
    (s1, vals1) = mapSourceValues h r1
    (s2, vals2) = mapSourceValues h r2
    in if mustDisagree vals1 vals2
      then Just False
      else if s1 == s2 && mustAgree vals1 vals2
        then Just True
        else Nothing
  where
    mustDisagree m1 m2 = M.foldl (||) False $ (M.intersectionWith (mustNeq h) m1 m2)
    mustAgree m1 m2 = let common = M.intersectionWith (mustEq h) m1 m2 in
      M.size m1 == M.size common && M.size m2 == M.size common && M.foldl (&&) True common
objectEq _ (MapValue _) (MapValue _) = internalError "Attempt to compare two maps"
objectEq _ v1 v2 = Just $ v1 == v2

mustEq h v1 v2 = case objectEq h v1 v2 of
  Just True -> True
  _ -> False  
mustNeq h v1 v2 = case objectEq h v1 v2 of
  Just False -> True
  _ -> False  
mayEq h v1 v2 = not $ mustNeq h v1 v2
mayNeq h v1 v2 = not $ mustEq h v1 v2
  
{- Store -}  

-- | Store: stores variable values at runtime 
type Store = Map Id Value

-- | A store with no variables
emptyStore :: Store
emptyStore = M.empty

-- | Pretty-printed store
storeDoc :: Store -> Doc
storeDoc vars = vsep $ map varDoc (M.toList vars)
  where varDoc (id, val) = text id <+> text "=" <+> valueDoc val
  
-- | 'userStore' @heap store@ : @store@ with all reference values completely dereferenced given @heap@
userStore :: Heap Value -> Store -> Store
userStore heap store = M.map (deepDeref heap) store

-- | 'functionCacheName' @name@ : name of a constant that stores cached applications of function @name@
-- (must be distinct from all global names)
functionCacheName name = "function " ++ name

{- Memory -}

-- | Dynamic part of the execution state
data Memory = Memory {
  _memLocals :: Store,                          -- ^ Local variable store
  _memGlobals :: Store,                         -- ^ Global variable store
  _memOld :: Store,                             -- ^ Old global variable store (in two-state contexts)
  _memConstants :: Store,                       -- ^ Constant and function cache
  _memHeap :: Heap Value                        -- ^ Heap
} deriving Eq

makeLenses ''Memory

-- | Empty memory
emptyMemory = Memory {
  _memLocals = emptyStore,
  _memGlobals = emptyStore,
  _memOld = emptyStore,
  _memConstants = emptyStore,
  _memHeap = emptyHeap
}

-- | Visible values of all identifiers in a memory (locals shadow globals) 
visibleVariables :: Memory -> Store
visibleVariables mem = (mem^.memLocals) `M.union` (mem^.memGlobals) `M.union` (mem^.memConstants)

-- | 'memoryDoc' @debug mem@ : either user or debug representation of @mem@, depending on @debug@
memoryDoc :: Bool -> Memory -> Doc
memoryDoc debug mem = vsep $ [text "Locals:" <+> storeDoc (storeRepr $ mem^.memLocals),
  text "Globals:" <+> storeDoc (storeRepr $ (mem^.memGlobals) `M.union` (mem^.memConstants)),
  text "Old values:" <+> storeDoc (storeRepr $ mem^.memOld)]
  ++ if debug then [text "Heap:" <+> heapDoc (mem^.memHeap)] else []
  where
    storeRepr store = if debug then store else userStore (mem^.memHeap) store
    
instance Show Memory where
  show mem = show $ memoryDoc True mem  

{- Environment -}
  
-- | Execution state
data Environment m = Environment
  {
    _envMemory :: Memory,                         -- ^ Variable values
    _envConstDefs :: Map Id Expression,           -- ^ Constant definitions
    _envConstConstraints :: Map Id [Expression],  -- ^ Constant constraints
    _envFunctions :: Map Id [FDef],               -- ^ Function definitions
    _envProcedures :: Map Id [PDef],              -- ^ Procedure definitions
    _envTypeContext :: Context,                   -- ^ Type context
    _envGenerator :: Generator m,                 -- ^ Input generator (used for non-deterministic choices)
    _envInOld :: Bool                             -- ^ Is an old expression currently being evaluated?
  }
  
makeLenses ''Environment
   
-- | 'initEnv' @tc gen@: Initial environment in a type context @tc@ with a value generator @gen@  
initEnv tc gen = Environment
  {
    _envMemory = emptyMemory,
    _envConstDefs = M.empty,
    _envConstConstraints = M.empty,
    _envFunctions = M.empty,
    _envProcedures = M.empty,
    _envTypeContext = tc,
    _envGenerator = gen,
    _envInOld = False
  }

-- | 'lookupConstConstraints' @id env@ : All constraints of constant @id@ in @env@
lookupConstConstraints id env = case M.lookup id (env^.envConstConstraints) of
  Nothing -> []
  Just cs -> cs
  
-- | 'lookupFunction' @id env@ : All definitions of function @id@ in @env@
lookupFunction id env = case M.lookup id (env^.envFunctions) of
  Nothing -> []
  Just defs -> defs    
  
-- | 'lookupProcedure' @id env@ : All definitions of procedure @id@ in @env@  
lookupProcedure id env = case M.lookup id (env^.envProcedures) of
  Nothing -> []
  Just defs -> defs 

-- Environment modifications  
setGlobal id val = over (envMemory.memGlobals) (M.insert id val)
setLocal id val = over (envMemory.memLocals) (M.insert id val)
setOld id val = over (envMemory.memOld) (M.insert id val)
setConst id val = over (envMemory.memConstants) (M.insert id val)
addConstantDef id def = over envConstDefs (M.insert id def)
addConstantConstraint id expr env = env { _envConstConstraints = M.insert id (lookupConstConstraints id env ++ [expr]) (_envConstConstraints env) }
addFunctionDefs id defs env = env { _envFunctions = M.insert id (lookupFunction id env ++ defs) (_envFunctions env) }
addProcedureDef id def env = env { _envProcedures = M.insert id (lookupProcedure id env ++ [def]) (_envProcedures env) } 
withHeap f env = let (res, h') = f (env^.envMemory.memHeap) in (res, set (envMemory.memHeap) h' env )  

-- | Pretty-printed set of function definitions
functionsDoc :: Map Id [FDef] -> Doc  
functionsDoc funcs = vsep $ map funcDoc (M.toList funcs)
  where 
    funcDoc (id, defs) = vsep $ map (funcsDefDoc id) defs
    funcsDefDoc id (FDef formals guard body) = exprDoc guard <+> text "->" <+> 
      text id <> parens (commaSep (map text formals)) <+> text "=" <+> exprDoc body