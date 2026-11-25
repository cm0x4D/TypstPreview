// Sample document for the Typst Quick Look extension
#set page(paper: "a4", margin: 2cm)
#set text(font: "New Computer Modern", size: 11pt, lang: "en")
#set heading(numbering: "1.1")

#let accent = rgb("#239dad")
#let note(body) = block(fill: accent.lighten(85%), inset: 8pt, radius: 4pt)[*Note:* #body]

= Introduction <intro>
This is *strong*, this is _emphasis_ and this is `inline raw`.
See @intro or visit https://typst.app for more.

- First item
- Second item with math $a^2 + b^2 = c^2$
+ Numbered
+ List

#note[Quick Look renders this with your local Typst installation.]

== Code
```rust
fn main() { println!("Hello"); }
```

#for i in range(3) [Item #(i + 1). ]

/* Block comment
   spanning lines */
$ sum_(k=1)^n k = (n(n+1)) / 2 $

#table(
  columns: (1fr, 2fr),
  [*Key*], [*Value*],
  [width], [#(12.5pt * 2)],
  [auto], [#auto],
)
