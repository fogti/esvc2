(*
From Coq.Init.Datatypes Require Import
  bool true false
  nat S O
  list nil cons
  option Some None
  .
*)

Definition Payload (FlowData:Type) : Type := FlowData -> FlowData.

Definition depCommutative {FlowData:Type} 
  (startValue:FlowData) (a:(Payload FlowData)) (b:(Payload FlowData))
:= (b (a startValue)) = (a (b startValue)).


Example test_idc0:
  depCommutative O (fun x => S x) (fun x => S (S x)).
Proof. simpl. reflexivity. Qed.

Example test_idc1:
  ~ (depCommutative (S O) (fun x => S x) (fun x => O)).
Proof. Admitted.

(*
Definition dLBinner {FlowData:Type}
  (position:nat) (startValue:FlowData) (lastBound:(option nat))
  (payloads:(list (Payload FlowData))) (toAdd:(Payload FlowData))
.
Admitted.

Definition determineLowerBound {FlowData:Type}
  (initialValue:FlowData)
  (payloads:list(Payload(FlowData)))
  (toAdd:Payload(FlowData))
:= (dLBinner O initialValue None payloads).
*)
