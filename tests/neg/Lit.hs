{-@ LIQUID "--expect-any-error" @-}
module Lit where

{-@ test :: {v:Int | v == 30} @-}
test = length "cat"
