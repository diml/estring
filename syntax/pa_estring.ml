(*
 * pa_estring.ml
 * -------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of estring.
 *)

open Printf
open Camlp4.PreCast
open EString_pervasives

(* +-------+
   | Utils |
   +-------+ *)

type 'a llist =
  | Nil of Loc.t
  | Cons of Loc.t * 'a * 'a llist

let loc_of_llist = function
  | Nil loc -> loc
  | Cons(loc, x, l) -> loc

let rec llength_rec acc = function
  | Nil _ -> acc
  | Cons(_, _, ll) -> llength_rec (acc + 1) ll

let llength ll = llength_rec 0 ll

let rec lfoldr f g = function
  | Nil loc -> g loc
  | Cons(loc, x, l) -> f loc x (lfoldr f g l)

let rec list_of_llist = function
  | Nil _ -> []
  | Cons(_, x, l) -> x :: list_of_llist l

let rec llist_of_list loc = function
  | [] -> Nil loc
  | x :: l -> Cons(loc, x, llist_of_list (Loc.move `start 1 loc) l)

let rec ldrop n l =
  if n <= 0 then
    l
  else match l with
    | Cons(_, _, l) -> ldrop (n - 1) l
    | l -> l

let rec lappend ll1 ll2 = match ll1 with
  | Nil _ -> ll1
  | Cons(loc, x, ll) -> Cons(loc, x, lappend ll ll2)

let llist_expr f ll = lfoldr (fun _loc x acc -> <:expr< $f _loc x$ :: $acc$ >>) (fun _loc -> <:expr< [] >>) ll
let llist_patt f ll = lfoldr (fun _loc x acc -> <:patt< $f _loc x$ :: $acc$ >>) (fun _loc -> <:patt< [] >>) ll

let estring_expr ll = llist_expr (fun _loc ch -> <:expr< $chr:Char.escaped ch$ >>) ll
let estring_patt ll = llist_patt (fun _loc ch -> <:patt< $chr:Char.escaped ch$ >>) ll

let unicode_expr ll =
  let e = llist_expr (fun _loc uch -> <:expr< $int:sprintf "0x%x" (EUChar.to_int uch)$ >>) ll in
  (* Here we know that the characters are correct so we can use
     Obj.magic safely *)
  let _loc = loc_of_llist ll in
  <:expr< (Obj.magic $e$ : EUChar.t list) >>

let uchar_expr _loc uch = <:expr< (Obj.magic $int:sprintf "0x%x" (EUChar.to_int uch)$ : EUChar.t) >>

IFDEF HAVE_PRIVATE THEN

let unicode_patt ll = llist_patt (fun _loc uch -> <:patt< $int:sprintf "0x%x" (EUChar.to_int uch)$ >>) ll
let uchar_expr _loc uch = <:expr< $int:sprintf "0x%x" (EUChar.to_int uch)$ >>

ELSE

(* If we do not have private types, then [UChar.t] is an abstract type
   and matching is not possible :( *)
let fail loc = Loc.raise loc (Stream.Error "you need ocaml >= 3.11 to use unicode in patterns")
let unicode_patt l = fail (loc_of_llist l)
let uchar_patt loc uch = fail loc

END

(* [parse_utf8_rec ll l] parse an estring as an UTF8-encoded unicode
   string. [l] is the estring and [ll] is the corresponding llist of
   chars *)
let rec parse_utf8_rec ll = function
  | [] -> Nil(loc_of_llist ll)
  | l -> match EUChar.utf8_try_next l with
      | `Success(uch, l) ->
          Cons(loc_of_llist ll, uch, parse_utf8_rec (ldrop (EUChar.utf8_length uch) ll) l)
      | `Failure msg ->
          Loc.raise (loc_of_llist ll)
            (Stream.Error
               (sprintf "failed to decode unicode string: %s" msg))

let parse_utf8 ll = parse_utf8_rec ll (list_of_llist ll)

let parse_utf8_char ll =
  let l = list_of_llist ll in
  match EUChar.utf8_try_next l with
    | `Success(uch, []) -> uch
    | `Success(uch, _) ->
        Loc.raise (loc_of_llist (ldrop (EUChar.utf8_length uch) ll))
          (Stream.Error "data remaining after unicode character")
    | `Failure msg ->
        Loc.raise (loc_of_llist ll)
          (Stream.Error
             (sprintf "failed to decode unicode character: %s" msg))

(* +--------------------+
   | Strings unescaping |
   +--------------------+ *)

(* String appears in the camlp4 ast as they apears in the source
   code. So if we want to process a string then we need to first
   unescape it. Camlp4 provide such a function
   (Camlp4.Struct.Token.Eval.string) but the problem is that we do not
   know exactly the location of unescaped characters:

   For instance: "\tx\tA" will be unescaped in " x A", and the
   position of "A" in the resulting string will be changed.

   So here is an implementation of an unescaping function which also
   compute the location of each unescaped characters. *)

module Unescape =
struct
  let add n loc = Loc.move `start n loc
  let inc loc = add 1 loc
  let addl n loc = Loc.move_line n loc
  let incl loc = addl 1 loc
  let resetl loc = addl 0 loc

  let dec x = Char.code x - Char.code '0'
  let hex = function
    | '0'..'9' as x -> Char.code x - Char.code '0'
    | 'a'..'f' as x -> Char.code x - Char.code 'a' + 10
    | 'A'..'F' as x -> Char.code x - Char.code 'A' + 10
    | x -> assert false

  let rec skip_indent cont loc = function
    | (' ' | '\t') :: l -> skip_indent cont (inc loc) l
    | l -> cont loc l

  let skip_opt_linefeed cont loc = function
    | '\n' :: l -> cont (incl loc) l
    | l -> cont loc l

  let rec string loc = function
    | [] -> Nil loc
    | '\\' :: l ->
        let loc = inc loc in
        begin match l with
          | '\n' :: l -> skip_indent string (incl loc) l
          | '\r' :: l -> skip_opt_linefeed (skip_indent string) (resetl loc) l
          | 'n' :: l -> Cons(loc, '\n', string (inc loc) l)
          | 'r' :: l -> Cons(loc, '\r', string (inc loc) l)
          | 't' :: l -> Cons(loc, '\t', string (inc loc) l)
          | 'b' :: l -> Cons(loc, '\b', string (inc loc) l)
          | '\\' :: l -> Cons(loc, '\\', string (inc loc) l)
          | '"' :: l  -> Cons(loc, '"', string (inc loc) l)
          | '\'' :: l -> Cons(loc, '\'', string (inc loc) l)
          | ' ' :: l -> Cons(loc, ' ', string (inc loc) l)
          | ('0'..'9' as c1) :: ('0'..'9' as c2) :: ('0'..'9' as c3) :: l ->
              Cons(loc,
                   char_of_int (100 * (dec c1) + 10 * (dec c2) + (dec c3)),
                   string (add 3 loc) l)
          | 'x'
            :: ('0'..'9' | 'a'..'f' | 'A'..'F' as c1)
            :: ('0'..'9' | 'a'..'f' | 'A'..'F' as c2) :: l ->
              Cons(loc,
                   char_of_int (16 * (hex c1) + (hex c2)),
                   string (add 3 loc) l)
          | _ -> Loc.raise loc (Stream.Error "illegal backslash")
        end
    | '\r' :: l -> Cons(loc, '\r', string (resetl loc) l)
    | '\n' :: l -> Cons(loc, '\n', string (incl loc) l)
    | ch :: l -> Cons(loc, ch, string (inc loc) l)
end

let unescape = Unescape.string

(* +-------------+
   | String tags |
   +-------------+ *)

(* In order to recognize expressions/patterns of the form [u"string"],
   [p"string"], ... without recognising [u "string"], [X.u"string"] we
   need to add a token filter.

   By the way the expansion need to be done at filtering time, so we
   need to remember the specifier a string use. For that we prepend it
   a special string containing the specifier.

   This special string must avoid colision with string generated by
   other syntax extension which do not tag string.
*)

let internal_tag = "ESTRING_INTERNAL_TAG"

let tag tag str = Printf.sprintf "%s[%c]%s" internal_tag tag str

let untag str =
  try
    let ilen = String.length internal_tag in
    if (String.sub str 0 ilen = internal_tag
        && str.[ilen] = '[' && str.[ilen + 2] = ']') then
      Some(str.[ilen + 1], String.sub str (ilen + 3) (String.length str - ilen - 3))
    else
      None
  with
      _ -> None

let make_tagged_stream stm =
  (* The previous token *)
  let previous = ref EOI

  (* The default specifier, it is first e for ``estring'' *)
  and default_specifier = ref 'e' in

  let rec func pos =
    try
      let prev = !previous
      and tok, loc = Stream.next stm in

      previous := tok;

      match tok with
          (* Parse directive [#estring_default] *)
        | KEYWORD "#" ->
            begin match Stream.npeek 3 stm with
              | [(LIDENT "estring_default", _); (BLANKS _, _); (LIDENT specifier, loc')] ->
                  begin match specifier with
                    | "e" | "n" | "u" ->
                        Stream.junk stm;
                        Stream.junk stm;
                        Stream.junk stm;
                        default_specifier := specifier.[0];
                        func pos
                    | _ ->
                        Loc.raise loc'
                          (Stream.Error
                             (sprintf "invalid default estring specifier %S, must be one of e, n or u" specifier))
                  end
              | _ ->
                  Some(tok, loc)
            end

        | LIDENT "n" when prev <> KEYWORD "." ->
            (* Immediatly ignore strings with the 'n' specifier, this
               is to avoid problems with other syntax extensions; for
               example in [INCLUDE "file.ml"], "file.ml" would get
               tagged and pa_macro would be confused *)
            begin match Stream.peek stm with
              | Some(STRING _ as tok, loc) ->
                  Stream.junk stm;
                  Some(tok, loc)
              | _ -> Some(tok, loc)
            end

        | LIDENT("e" | "u" | "p" | "s" as id) when prev <> KEYWORD "." ->
            begin match Stream.peek stm with
              | Some(STRING(s, orig), loc) ->
                  Stream.junk stm;
                  Some(STRING(tag id.[0] s, tag id.[0] orig), loc)
              | _ -> Some(tok, loc)
            end

        | UIDENT("U" as id) when prev <> KEYWORD "." ->
            begin match Stream.peek stm with
              | Some(STRING(s, orig), loc) ->
                  Stream.junk stm;
                  Some(STRING(tag id.[0] s, tag id.[0] orig), loc)
              | _ -> Some(tok, loc)
            end

        | STRING(s, orig) ->
            let spec = !default_specifier in
            if spec = 'n' then
              Some(tok, loc)
            else
              Some(STRING(tag spec s, tag spec orig), loc)

        | _ ->
            Some(tok, loc)
    with
        Stream.Failure -> None

  in
  Stream.from func

(* +--------------------+
   | Identifier mapping |
   +--------------------+ *)

(* In long specification of format string, i.e. things between '{' and
   '}' we prepend a string to any identifier, like "print__" or "scan__".

   This avoid name colisition between combinators *)

let prefix_ident prefix =
  let rec aux = function
    | <:ident@_loc< $id:x$.$y$ >> -> <:ident< $id:x$.$aux y$ >>
    | <:ident@_loc< $lid:x$ >> -> <:ident< $lid:prefix ^ "__" ^ x$ >>
    | x -> x
  in
object
  inherit Ast.map
  method ident = aux
end

let printer_map = prefix_ident "print"
let scanner_map = prefix_ident "scan"

(* +-----------------------+
   | Format string parsing |
   +-----------------------+ *)

exception Premature_end of Loc.t

type format_type =
  | Printer
  | Scanner

let ( <:: ) x (l, rest) = (x :: l, rest)

(* [get_long_spec deep l] try to extract the long specification ending
   in [l], [deep] being the numbre of '{' not yet closed.

   It return the long specification and the rest of [l] *)
let rec get_long_spec deep = function
  | Nil loc ->
      Loc.raise loc (Stream.Error "'}' missing in format")
  | Cons(_, '%', Nil loc) ->
      raise (Premature_end loc)
  | Cons(_, '%', Cons(_, x, rest)) ->
      let spec, rest = get_long_spec deep rest in
      ('%' :: x :: spec, rest)
  | Cons(_, '}', rest) ->
      if deep = 0 then
        ([], rest)
      else
        '}' <:: get_long_spec (deep - 1) rest
  | Cons(_, '{', rest) ->
      '{' <:: get_long_spec (deep + 1) rest
  | Cons(_, ch, rest) ->
      ch <:: get_long_spec deep rest

(* [get_const typ l] extract the constart part of [l], i.e. the
   longest prefix without any specification conversion *)
let rec get_const typ l = match l with
  | Nil _ ->
      ([], l)

  | Cons(_, '%', l') ->
      begin match l' with
        | Cons(_, ('%' | '{' | '}' as ch), l) ->
            ch <:: get_const typ l
        | _ ->
            ([], l)
      end

  | Cons(_, '{', _) ->
      ([], l)

  | Cons(_, '@', l') when typ = Printer ->
      begin match l' with
        | Cons(_, '@', l) ->
            '@' <:: get_const typ l
        | _ ->
            ([], l)
      end

  | Cons(_, x, l) ->
      x <:: get_const typ l

(* [nconst_expr _loc l] expression for a constant string printer *)
let nconst_expr _loc l = <:expr< EPrintf.nconst $str:string_of_estring (EString.escaped l)$ >>

(* [get_box_kind l] extract the kind of a box: b, h, v, hv or hov *)
let get_box_opener l =
  let rec aux = function
    | Cons(_, ('a'..'z' as ch), l) ->
        ch <:: aux l
    | l ->
        ([], l)
  in
  let kind, rest = aux l in
  let kind = string_of_estring kind in
  if not (List.mem kind [""; "b"; "h"; "v"; "hv"; "hov"]) then
    Loc.raise (loc_of_llist l) (Stream.Error ("invalid box kind: " ^ kind))
  else
    (kind, rest)

(* [skip_space l] skip space at the beginning if [l] *)
let rec skip_space = function
  | Cons(_, ' ', l) -> skip_space l
  | l -> l

(* [get_format_arguments default f l] if [l] start with '<...>' then
   read this part as format specification arguments using [f],
   otherwise return [default] *)
let get_format_arguments default f = function
  | Cons(_, '<', l) ->
      let result, l = f l in
      begin match l with
        | Cons(_, '>', l) -> (result, l)
        | l -> Loc.raise (loc_of_llist l) (Stream.Error "'>' missing")
      end
  | l ->
      (default, l)

(* [get_int default l] read an integer argument at the begining of [l] *)
let get_int default l =
  let rec get_digits = function
    | Cons(_, ('0'..'9' | '-' as ch), l) -> ch <:: get_digits l
    | l -> ([], l)
  in
  let _loc = loc_of_llist l in
  let digits, l = get_digits l in
  let n = match digits with
    | [] -> default
    | _ -> try int_of_estring digits with
          _ -> Loc.raise _loc (Stream.Error "invalid integer offset")
  in
  (<:expr< $int:string_of_int n$ >>, l)

(* [get_next_printer typ l] extract the next printer of [l] *)
let rec get_next_printer typ = function
  | Nil _ ->
      None

  | Cons(_loc, '%', l) -> begin match l with
      | Cons(_, ('a'..'z' | 'A'..'Z' as ch1), Cons(_, ('a'..'z' | 'A'..'Z' as ch2), l)) ->
          Some(<:expr< $lid:sprintf "print__%c%c" ch1 ch2$ >>, l)

      | Cons(_, ('a'..'z' | 'A'..'Z' as ch), l) ->
          Some(<:expr< $lid:sprintf "print__%c" ch$ >>, l)

      | Cons(_, '!', l) ->
          Some(<:expr< EPrintf.print__print_flush >>, l)

      | Cons(_, ('{' | '}' | '%' as ch), l) ->
          let const, next = get_const typ l in
          Some(nconst_expr _loc (ch :: const), next)

      | Cons(loc, ch, l) ->
          Loc.raise loc (Stream.Error (Printf.sprintf "invalid conversion specification character: %C" ch))

      | Nil loc ->
          raise (Premature_end loc)
    end

  | Cons(_, '{', l) ->
      let spec, rest = get_long_spec 0 l in
      let e_spec = (match typ with
                      | Printer -> printer_map
                      | Scanner -> scanner_map)#expr
        (Gram.parse Syntax.expr_eoi (loc_of_llist l) (Stream.of_list spec)) in
      Some(e_spec, rest)

  | Cons(_loc, '@', l) when typ = Printer -> begin match l with
      | Cons(_, '@', l) ->
          let const, next = get_const typ l in
          Some(nconst_expr _loc ('@' :: const), next)

      | Cons(_, '[', l) ->
          let open_expr, l = get_format_arguments <:expr< EPrintf.print__open_box 0 >>
            (fun l ->
               let _loc = loc_of_llist l in
               let kind, l = get_box_opener l in
               match kind with
                 | "h" ->
                     (<:expr< EPrintf.print__open_hbox >>, l)
                 | _ ->
                     let l = skip_space l in
                     let ofs, l = get_int 0 l in
                     (<:expr< EPrintf.$lid:"print__open_" ^ kind ^ "box"$ $ofs$ >>, l)) l in
          Some(open_expr, l)

      | Cons(_, ']', l) ->
          Some(<:expr< EPrintf.print__close_box >>, l)

      | Cons(_, ',', l) ->
          Some(<:expr< EPrintf.print__print_cut >>, l)

      | Cons(_, ' ', l) ->
          Some(<:expr< EPrintf.print__print_space >>, l)

      | Cons(_, '\n', l) ->
          Some(<:expr< EPrintf.print__force_newline >>, l)

      | Cons(_, ';', l) ->
          let break_expr, l = get_format_arguments <:expr< EPrintf.print__print_space >>
            (fun l ->
               let _loc = loc_of_llist l in
               let nspaces, l = get_int 1 l in
               let l = skip_space l in
               let offset, l = get_int 0 l in
               (<:expr< EPrintf.print__print_break $nspaces$ $offset$ >>, l)) l in
          Some(break_expr, l)

      | Cons(_, '?', l) ->
          Some(<:expr< EPrintf.print__print_flush >>, l)

      | Cons(_, '.', l) ->
          Some(<:expr< EPrintf.print__print_newline >>, l)

      | Cons(_, '{', l) ->
          let tag, l = get_format_arguments <:expr< "" >>
            (fun l ->
               let _loc = loc_of_llist l in
               let rec get_tag = function
                 | Cons(_, '>', _) as l -> ([], l)
                 | Cons(_, ch, l) -> ch <:: get_tag l
                 | Nil _ as l -> ([], l)
               in
               let tag, l = get_tag l in
               (<:expr< $str:string_of_estring (EString.escaped tag)$ >>, l)) l in
          Some(<:expr< EPrintf.print__open_tag $tag$ >>, l)

      | Cons(_, '}', l) ->
          Some(<:expr< EPrintf.print__close_tag >>, l)

      | Cons(loc, ch, _) ->
          Loc.raise loc (Stream.Error (sprintf "invalid format specification character (%C)" ch))

      | Nil loc ->
          raise (Premature_end loc)
    end

  | Cons(loc, ch, l) ->
      let const, rest = get_const typ l in
      Some(nconst_expr loc (ch :: const), rest)

(* [make_format mapper l] create a format expression from a format
   string *)
let rec make_format mapper l =
  let _loc = loc_of_llist l in
  match get_next_printer mapper l with
    | None ->
        <:expr< EPrintf.nil >>
    | Some(pr_expr, Nil _) ->
        pr_expr
    | Some(pr_expr, rest) ->
        <:expr< EPrintf.cons $pr_expr$ $make_format mapper rest$ >>

(* Handle format parsing error *)
let safe_make_format mapper l =
  try
    let _loc = loc_of_llist l in
    (* Make a function so type variables can be generalized *)
    <:expr< fun cont pp -> $make_format mapper l$ cont pp >>
  with
    | Premature_end loc ->
        Loc.raise loc (Stream.Error "premature end of format")

(* +--------------------+
   | Strings conversion |
   +--------------------+ *)

(* Handle unknown specifiers, this is only for debugging purpose since
   it should never happen *)
let handle_specifier_error loc specifier =
  Loc.raise loc (Stream.Error (sprintf "unknown specifier %C" specifier))

(* [expr_of_tagged_string loc l tag] create an expression
   from an tagged string *)
let expr_of_tagged_string _loc l = function
  | 'e' -> estring_expr l
  | 'u' -> unicode_expr (parse_utf8 l)
  | 'U' -> uchar_expr _loc (parse_utf8_char l)
  | 'n' -> <:expr< $str:String.escaped (string_of_estring (list_of_llist l))$ >>
  | 'p' -> safe_make_format Printer l
  | 's' -> safe_make_format Scanner l
  | spc -> handle_specifier_error _loc spc

(* [expr_of_tagged_string loc l tag] create an pattern from
   an tagged string *)
let patt_of_tagged_string _loc l = function
  | 'e' -> estring_patt l
  | 'u' -> unicode_patt (parse_utf8 l)
  | 'U' -> uchar_patt _loc (parse_utf8_char l)
  | 'n' -> <:patt< $str:String.escaped (string_of_estring (list_of_llist l))$ >>
  | 'p' | 's' -> Loc.raise _loc (Stream.Error "format string are not allowed in pattern")
  | spc -> handle_specifier_error _loc spc

(* [with_tag if_not_tagged func loc str]

   If [str] contain an tag then extract it and call [func],
   otherwise return [if_not_tagged] *)
let with_tag if_not_tagged func loc str =
  match untag str with
    | Some(tag, str) -> func loc (unescape loc (estring_of_string str)) tag
    | None -> if_not_tagged

let map = object
  inherit Ast.map as super

  method expr e = match super#expr e with
    | <:expr@loc< $str:s$ >> as e -> with_tag e expr_of_tagged_string loc s
    | e -> e

  method patt p = match super#patt p with
    | <:patt@loc< $str:s$ >> as p -> with_tag p patt_of_tagged_string loc s
    | p -> p
end

(* +--------------+
   | Registration |
   +--------------+ *)

let _ =
  (* Register the token filter for tags *)
  Gram.Token.Filter.define_filter (Gram.get_filter ()) (fun filter stm -> filter (make_tagged_stream stm));

  (* Register the string mapper *)
  AstFilters.register_str_item_filter map#str_item;

  (* Register filters for automatically opening [EString_pervasives]
     in implementation and interface modules *)
  AstFilters.register_str_item_filter
    (fun s ->
       let _loc = Ast.loc_of_str_item s in
       <:str_item< open EString_pervasives;; $s$ >>);
  AstFilters.register_sig_item_filter
    (fun s ->
       let _loc = Ast.loc_of_sig_item s in
       <:sig_item< open EString_pervasives;; $s$ >>)
