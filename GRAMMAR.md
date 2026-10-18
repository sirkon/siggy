# A grammar definition and interpretation rules

## Tokens

Here EOF is produced by the lexer; the parser never sees a missing-token case

```
  ASSIGN   '='
  START    '{'
  END      '}'
  COMMA    ','
  COMMENT  '#' … until end of line (skipped by the lexer, never emitted)
  LITERAL  all characters with ascii > 32, except '=', '{', '}', ',', '"', '#'
  QUOTED   '"' … '"', with JSON-style escapes \" and \\
```

## Grammar

```
document   = { assign } ;                                 // until END or EOF
assign     = LITERAL ASSIGN value ;
value      = LITERAL block                                // peek(1): LITERAL START
           | block
           | LITERAL
           | QUOTED ;
block      = START END                                    // peek(1): END → empty
           | START document END                           // peek(2): LITERAL ASSIGN
           | START list END ;                             // otherwise
list       = list_space | list_comma ;
list_space = list_item { list_item } ;                    // space only between elements
list_comma = list_item { COMMA list_item } [ COMMA ] ;    // comma only, optional trailing comma
list_item  = value ;
```

## Disambiguation

1. block: after START, peek one token.
   - END → empty.
   - otherwise peek two: LITERAL + ASSIGN → document; otherwise → list.
2. LITERAL vs LITERAL block in `value`: after LITERAL, peek one token.
   - START → Tagged{tag, block}; otherwise → Literal.
3. list mode: parse first list_item, then peek. COMMA → comma mode for the WHOLE
   list (allow trailing comma before END). Otherwise → space mode (COMMA anywhere
   is an error). Mode is fixed after the first item.
4. COMMA is never allowed inside document.
5. `10..12` is one LITERAL; the parser does not interpret `..`.
6. `{ }` is valid (empty). Its meaning (empty list / empty struct / invalid
   payload for a tag) is decided by the deserializer, not by the parser.
