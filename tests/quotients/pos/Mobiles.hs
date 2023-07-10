module Mobiles () where

data Tree a = Leaf | Bin a (Tree a) (Tree a)

{-@
  data Mobile a
    =  Tree a
    |/ swap :: x:a -> t:Mobile a -> u:Mobile a -> Bin x t u == Bin x u t
@-}

{-@ test :: Mobile a -> Mobile a @-}
test :: Tree a -> Tree a
test Leaf              = Leaf
-- test (Bin x Leaf Leaf) = Leaf
test (Bin x t u)       = Bin x t u

{-
{-@ tmap :: (a -> b) -> Mobile a -> Mobile b @-} 
tmap :: (a -> b) -> Tree a -> Tree b
tmap f Leaf = Leaf
tmap f (Bin x t u) = Bin (f x) (tmap f t) (tmap f u)
-}