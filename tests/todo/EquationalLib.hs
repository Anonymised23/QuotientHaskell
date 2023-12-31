
module EquationalLib where 


-------------------------------------------------------------------------------
-- | Proof is just unit
-------------------------------------------------------------------------------

type Proof = ()

-------------------------------------------------------------------------------
-- | Casting expressions to Proof using the "postfix" `-*- QED` 
-------------------------------------------------------------------------------

data QED = QED 

infixl 2 -*-
(-*-) :: a -> QED -> Proof
_ -*- QED = () 

-------------------------------------------------------------------------------
-- | Equational and Implication Reasoning operators 
-------------------------------------------------------------------------------

infixl 3 ==., ==> 


{-@ (==.) :: x:a -> y:{a | x == y} -> {v:a | v == y && v == x} @-}
(==.) :: a -> a -> a 
_ ==. x = x 
{-# INLINE (==.) #-} 


{-@ (==>) :: x:Bool -> y:{Bool | x => y} -> {b:Bool | (x => b) && (y == b) }  @-}
(==>) :: Bool -> Bool -> Bool 
_ ==> y = y  


-------------------------------------------------------------------------------
-- | Use `x === y` to state equality when `x` and `y` are not Eq, 
-- | e.g., are functions
-------------------------------------------------------------------------------

{-@ assume (===) :: x:a -> y:a -> {p:Bool | (x == y) <=> p } @-}
(===) :: a -> a -> Bool
_ === _ = True  

-------------------------------------------------------------------------------
-- | Explanations
-------------------------------------------------------------------------------

infixl 3 ?

{-@ (?) :: forall a b <pa :: a -> Bool>. x:a<pa> -> b -> {o:a<pa> | x == o} @-}
(?) :: a -> b -> a 
x ? _ = x 
{-# INLINE (?)   #-} 

-- For the type of (?), see
-- https://github.com/nikivazou/ccc/issues/11

-------------------------------------------------------------------------------
-- | Assert intermediate steps of the proof 
-------------------------------------------------------------------------------

{-@ assert :: b:{Bool | b}  -> () @-} 
assert :: Bool -> () 
assert _ = ()
