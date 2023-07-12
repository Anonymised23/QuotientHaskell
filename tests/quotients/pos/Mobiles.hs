module Mobiles () where

{-@
data SInt
  = Int
  |/ eqS :: m:Int -> n:{ n : Int | n < m} -> m == n
@-}

{-
{-@ example :: SInt -> SInt @-}
example :: Int -> Int
example 0 = 0
example m = m-}


data Tree a = Leaf | Bin a (Tree a) (Tree a)

{-@
  data Mobile a
    =  Tree a
    |/ swap :: x:a -> t:Mobile a -> u:Mobile a -> Bin x t u == Bin x u t
@-}

{-@ example :: p:Bool -> q:Bool -> x:a -> y:a -> { (if (p && q) then x else y) == (if (q && p) then x else y) } @-}
example :: Bool -> Bool -> a -> a -> ()
example _ _ _ _ = ()

{-@ test :: Mobile a -> Mobile a @-}
test :: Tree a -> Tree a
test Leaf              = Leaf
test (Bin x Leaf t)    = Leaf
test (Bin x t u)       = Bin x t u

{-
{-@ tmap :: (a -> b) -> Mobile a -> Mobile b @-} 
tmap :: (a -> b) -> Tree a -> Tree b
tmap f Leaf = Leaf
tmap f (Bin x t u) = Bin (f x) (tmap f t) (tmap f u)-}
