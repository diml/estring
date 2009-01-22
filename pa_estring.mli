(*
 * pa_estring.mli
 * --------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of estring.
 *)

(** The pa_estring syntax extension *)

open Camlp4.PreCast

type specifier = string
    (** Type of a string specifier (the letters just before the
        string) *)

val specifier : Loc.t -> specifier option
  (** Returns the specifier associated to a string location *)

(** {6 Specifier registration} *)

val register_expr_specifier : ?shared:bool -> specifier -> (Loc.t -> string -> Ast.expr) -> unit
  (** [register_expr_specifier ?shared spec f] registers [f] as an
      mapping function for string with the specifier [spec] in
      expressions.

      If [shared] is true, the resulting expression will be defined as
      a global constant, at the begining of the file. [shared]
      defaults to [false]. *)

val register_patt_specifier : specifier -> (Loc.t -> string -> Ast.patt) -> unit
  (** [register_patt_specifier spec f] same thing but for strings in
      patterns *)

val register_when_patt_specifier : specifier -> (Loc.t -> Ast.ident -> string -> Ast.expr) -> unit
  (** [register_when_patt_specifier spec f] same as
      [register_patt_specifier] but the string will be tested by a
      'when' clause. [f] takes as argument the identifier used in the
      pattern and the string. *)

(** Note: for more complicated case you must write your must register
    your own ast filter *)

(** {6 Shared expression} *)

val register_shared_expr : Ast.expr -> string
  (** [register_shared_expr expr] registers [expr] as a shared
      constant and return the identifier to which it is bound. The
      binding will be placed at the beging of the file. *)

(** {6 Lists with location} *)

(** We may want to know the location of each characters in a
    string. In order to do this we deal with strings as list of
    characters with location. The type [(char * Loc.t) list] is not
    suitable since we do not know the location of the end of the
    list. The right choise is: *)

type 'a llist =
  | Nil of Loc.t
  | Cons of Loc.t * 'a * 'a llist

val loc_of_llist : 'a llist -> Loc.t
  (** Returns the location of the first element of a llist *)

val llength : 'a llist -> int
  (** Returns the length of a llist *)

val lfoldr : (Loc.t -> 'a -> 'acc -> 'acc) -> (Loc.t -> 'acc) -> 'a llist -> 'acc
  (** [lfoldr f g l] fold_right-like function for llist.

      For example:

      {[
        lfoldr f g (Cons(loc1, 1, Cons(loc2, 2, Nil loc3)))
      ]}

      is the same as:

      {[
        f loc1 1 (f loc2 2 (g loc3))
      ]}
  *)

val list_of_llist : 'a llist -> 'a list
  (** Returns the list of elements contained in a llist *)

val llist_of_list : Loc.t -> 'a list -> 'a llist
  (** [llist_of_list loc l] Create a llist with all elements from [l].
      The nth element will be at loc + n. *)

val ldrop : int -> 'a llist -> 'a llist
  (** [ldrop count ll] returns [ll] without its firsts [count]
      elements. *)

val ltake : int -> 'a llist -> 'a llist
  (** [ltake count ll] returns the firsts [count] elements of [ll]. *)

val lappend : 'a llist -> 'a llist -> 'a llist
  (** [lappend ll1 ll2] appends [ll2] to [ll1] *)

val llist_expr : (Loc.t -> 'a -> Ast.expr) -> 'a llist -> Ast.expr
  (** [llist_expr f ll] returns the expression representing a list
      with element obtained by applying [f] on element of [ll] *)

val llist_patt : (Loc.t -> 'a -> Ast.patt) -> 'a llist -> Ast.patt
  (** [llist_patt f ll] same as {!llist_expr} but for patterns *)

(** {6 String unescaping} *)

val unescape : Loc.t -> string -> char llist
  (** [unescape loc str] returns the unescaped version of [str] where
      each unescaped character position has been computed *)
