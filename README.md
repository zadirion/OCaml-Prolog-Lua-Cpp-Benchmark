*Important to note* 
The bytecode OCaml is the one used here, not the native one. This is because for my purposes I needed to evaluate various bytecode languages for game scripting purposes, and how they compare to C++ as a reference.

Also the tests are quite imperfect because each individual run is a newly spawned process, so we pay the cost of bootstrapping said language and process and that ends up counted in the benchmark

Below are the results of various fibonacci implementations in each language.

Fib(30):

```
Language Variant  N   AvgMs Runs
-------- -------  -   ----- ----
C++      Tail    30   15.49  300
Lua      Fast    30   16.21  300
Lua      Tail    30   16.84  300
C++      Fast    30   16.85  300
C++      Naive   30   20.48  300
OCamlbc  Fast    30   34.59  300
OCamlbc  Tail    30   41.08  300
Prolog   Fast    30   49.08  300
Prolog   Tail    30   50.09  300
Lua      Naive   30  104.10  300
OCamlbc  Naive   30  135.14  300
Prolog   Naive   30 1467.00  300
```

Fib(45)

```
Language Variant  N     AvgMs Runs
-------- -------  -     ----- ----
Lua      Tail    45     19.31   30
Lua      Fast    45     20.62   30
OCamlbc  Fast    45     32.82   30
OCamlbc  Tail    45     43.78   30
Prolog   Tail    45     47.09   30
Prolog   Fast    45     47.55   30
Lua      Naive   35   1085.24   30
Prolog   Naive   30   1382.45   30
OCamlbc  Naive   45 100051.00   30
```
