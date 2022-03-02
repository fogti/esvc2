module Esvc2

record Item a where
  constructor MkItem
  dep : Nat
  tiebreak : Nat
  payload : a -> a

determineLowerBound : Eq a => a -> List (a -> a) -> (a -> a) -> Maybe Nat
determineLowerBound _ Nil _ = Nothing
determineLowerBound init (op::ops) tadd = case determineLowerBound next ops tadd of
    Just x => Just (S x)
    Nothing => if (tadd next) == (op (tadd init))
      then Nothing
      else Just Z
  where
    next = op init

private
determineUpperBound : Ord a => List a -> a -> (List a, List a)
determineUpperBound Nil _ = (Nil, Nil)
determineUpperBound (op::ops) tadd = if tadd < op
    then (x::op, y)
    else ([], op::ops)
  where
    (x, y) = determineUpperBound ops tadd

data InsertResult a = InsertOk (List (Item a)) (Item a) (List (Item a)) | LowerBoundMismatches (Maybe Nat)

||| insert $ops $initialValue $tiebreak $payload $expectLowerBound
insert : Eq a => List (Item a) -> a -> Nat -> (a -> a) -> Maybe Maybe Nat -> InsertResult a
insert ops init tiebreak tadd xlb =
    if lbok
      then ?...
      else LowerBoundMismatches lb
  where
    lb : Maybe Nat
    lb = determineLowerBound init (map payload ops) tadd
    lbok : Bool
    lbok = case xlb of
      Just x => lb == x
      Nothing => True
    uboffs : Nat
    uboffs = determineUpperBound (map tiebreak (offset lb ops)) tiebreak
