{-# OPTIONS --cumulativity #-}

open import Agda.Primitive
open import Agda.Builtin.Nat
open import Agda.Builtin.Equality

module _ where

variable
  ℓ ℓ′ ℓ₁ ℓ₂ : Level
  A B C : Set ℓ
  k l m n : Nat

lone ltwo lthree : Level
lone = lsuc lzero
ltwo = lsuc lone
lthree = lsuc ltwo

set0 : Set₂
set0 = Set₀

set1 : Set₂
set1 = Set₁

lift : ∀ {ℓ ℓ′} → Set ℓ → Set (ℓ ⊔ ℓ′)
lift x = x

data List {a : Level} (A : Set a) : Set a where
  []  : List A
  _∷_ : (x : A) (xs : List A) → List A

List-test₁ : (A : Set) → List {lone} A
List-test₁ A = []

lower-List : ∀ {ℓ ℓ′} {A : Set ℓ} → List {ℓ ⊔ ℓ′} A → List {ℓ} A
lower-List [] = []
lower-List {ℓ} {ℓ′} (x ∷ xs) = x ∷ lower-List {ℓ} {ℓ′} xs

lower-List-test₁ : {A : Set} → List {lthree} A → List {lone} A
lower-List-test₁ = lower-List

map : {ℓ : Level} {A B : Set ℓ} (f : A → B) → List {ℓ} A → List {ℓ} B
map f [] = []
map f (x ∷ xs) = f x ∷ map f xs

map00 : {A B : Set} (f : A → B) → List A → List {lzero} B
map00 = map

map01 : {A : Set} {B : Set₁} (f : A → B) → List A → List {lone} B
map01 = map

map10 : {A : Set₁} {B : Set} (f : A → B) → List A → List {lone} B
map10 = map

map20 : {A : Set₂} {B : Set} (f : A → B) → List A → List {ltwo} B
map20 = map

data Vec {ℓ} (A : Set ℓ) : Nat → Set ℓ where
  [] : Vec A 0
  _∷_ : A → Vec {ℓ} A n → Vec A (suc n)

module Without-Cumulativity where

  N-ary-level : Level → Level → Nat → Level
  N-ary-level ℓ₁ ℓ₂ zero    = ℓ₂
  N-ary-level ℓ₁ ℓ₂ (suc n) = ℓ₁ ⊔ N-ary-level ℓ₁ ℓ₂ n

  N-ary : ∀ (n : Nat) → Set ℓ₁ → Set ℓ₂ → Set (N-ary-level ℓ₁ ℓ₂ n)
  N-ary          zero    A B = B
  N-ary {ℓ₁} {ℓ₂} (suc n) A B = A → N-ary {ℓ₁} {ℓ₂} n A B

module With-Cumulativity where

  N-ary : Nat → Set ℓ₁ → Set ℓ₂ → Set (ℓ₁ ⊔ ℓ₂)
  N-ary          zero    A B = B
  N-ary {ℓ₁} {ℓ₂} (suc n) A B = A → N-ary {ℓ₁} {ℓ₂} n A B

  curryⁿ : ∀ {A : Set ℓ} {B : Set ℓ′} {n} → (Vec {ℓ} A n → B) → N-ary {ℓ} {ℓ′} n A B
  curryⁿ {n = zero}  f = f []
  curryⁿ {n = suc n} f = λ x → curryⁿ λ xs → f (x ∷ xs)

  _$ⁿ_ : ∀ {A : Set ℓ} {B : Set ℓ′} {n} → N-ary {ℓ} {ℓ′} n A B → (Vec {ℓ} A n → B)
  f $ⁿ []       = f
  f $ⁿ (x ∷ xs) = f x $ⁿ xs

  ∀ⁿ : ∀ {A : Set ℓ} n → N-ary {ℓ} {lsuc ℓ′} n A (Set ℓ′) → Set (ℓ ⊔ ℓ′)
  ∀ⁿ zero    P = P
  ∀ⁿ (suc n) P = ∀ x → ∀ⁿ n (P x)
