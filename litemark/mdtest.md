# **LiteNotes** *Demo* ~~Example~~

**LiteNotes** is a native Markdown viewer plugin for LiteXL. It renders `markdown` files directly in the editor using a custom Lua layout engine.

## `Usage` Guide

This document demonstrates the current rendering capabilities. You can view your notes in **Read Mode** or switch to standard editing.

- **Workflow**:
  - `Read Mode`: Clean layout for viewing notes.
  - `Edit Mode`: Standard LiteXL document editor.
  - *Double-click* anywhere to toggle modes.
- **Syntax Support**:
  1. **Headers**: Various sizes are supported.
  2. **Text**: Standard styles like **bold** and *italic*.
  3. **Lists**: Supports ordered and unordered nesting.

# to do list
  1. remember
  - [ ] get eggs
  - [x] get milks
  - **FOR DOG:**
    - [ ] ~~Crunchies~~
    - [x] Kibble
    - [ ] 

---

### Code Styling

Code blocks are supported with dedicated background rendering (`style.line_highlight`) and monospaced fonts.

```lua
local function foo(bar)
  -- Check for indentation handling
  if bar then
    print("Hello World")
    return true
  end
  
  return false
end
```

# LiteNotes Syntax Highlight Test

This file tests the rendering of code fences with various language identifiers.

## Core Languages

### Lua
```lua
local function hello(name)
  print("Hello, " .. name)
  return true
end
````

### C

```c
#include <stdio.h>

int main() {
    printf("Hello World\n");
    return 0;
}
```

### C++

```cpp
#include <iostream>
using namespace std;

class Box {
   public:
      double length;   // Length of a box
};
```

### Python

```python
def fib(n):
    """Print a Fibonacci series up to n."""
    a, b = 0, 1
    while a < n:
        print(a, end=' ')
        a, b = b, a+b
```

## Web Stack

### JavaScript

```javascript
const element = document.getElementById("demo");
element.innerHTML = "Hello JavaScript!";
// Complex regex test
const re = /ab+c/;
```

### JSON

```json
{
  "name": "LiteNotes",
  "version": 1.0,
  "features": ["syntax", "rendering"]
}
```

### HTML

```html
<!DOCTYPE html>
<html>
<body>
    <h1>My First Heading</h1>
    <p>My first paragraph.</p>
</body>
</html>
```

### CSS

```css
body {
  background-color: lightblue;
}
h1 {
  color: white;
  text-align: center;
}
```

## Systems / Modern

### Rust

```rust
fn main() {
    let x = 5;
    let y = 10;
    println!("x + y = {}", x + y);
}
```

### Go

```go
package main
import "fmt"

func main() {
    fmt.Println("Hello, World!")
}
```

### Odin

```odin
package main
import "core:fmt"

main :: proc() {
    fmt.println("Hellope World");
}
```

### Bash / Shell

```bash
#!/bin/bash
echo "Deploying updates..."
# Loop through files
for f in *.txt; do
    echo "Processing $f"
done
```

## Edge Cases

### Ruby

```ruby
class Greeter
  def initialize(name = "World")
    @name = name
  end
  def say_hi
    puts "Hi #{@name}!"
  end
end
```

### Markdown (Recursive)

```markdown
# Header
* List item
* [Link](http://google.com)
```

### No Language (Should be monochrome)

```
This block has no language tag.
It should render using the default code color.
```

### Unknown Language (Should fallback gracefully)

```brainfuck
++++++++++[>+++++++>++++++++++>+++>+<<<<-]>++.>+.+++++++..+++.>++.
```

```
```
