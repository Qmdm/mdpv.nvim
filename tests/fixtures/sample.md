---
title: FRONTMATTER_TITLE_VALUE
tags: [alpha, beta]
authors:
  - hitori
build:
  status: passing
  ci: local
---

# Sample Document

Some **bold**, _italic_, `inline code`, ~~strikethrough~~, and a bare autolink
https://example.com plus an [inline link](https://example.com/page).

## Duplicate Heading

## Duplicate Heading

### Code

```lua
local function greet(name)
  return ('hello %s'):format(name)
end
```

```text
plain fenced block
```

    indented code block

### Table

| Feature   | Status | Notes          |
| --------- | :----: | -------------- |
| Tables    |   ✅   | GFM pipes      |
| Alignment |   ✅   | centered cell  |

### Tasks

- [x] shipped thing
- [ ] pending thing
- regular item

### Alerts

> [!NOTE]
> Useful information that users should know.

> [!WARNING]
> Critical content demanding attention.

> Regular blockquote, not an alert.

### Callouts

> [!success] All **checks** passed
> Obsidian callout with a custom title.

> [!faq]- Are callouts foldable?
> Yes, and this one starts collapsed.

> [!tip]+ Pinned open
> Foldable callout, expanded by default.

> [!danger]
> Obsidian type with a default title.

> [!question] Can callouts nest?
>
> > [!todo] Inner callout
> > Nested one level down.

> [!unknown]
> Not a callout type, stays a blockquote.

### Math

Euler's identity $e^{i\pi} + 1 = 0$ inline, five dollars ($5) untouched.

$$
\int_0^1 x^2 \, dx = \frac{1}{3}
$$

```math
a^2 + b^2 = c^2
```

### Mermaid

```mermaid
graph TD
  A[Edit buffer] --> B{Debounce}
  B --> C[SSE push]
```

### Emoji

Ship it :rocket: :tada:

### Footnotes

Here is a claim.[^1]

[^1]: And here is the footnote text.

### Media

![local image](img.png)

<details><summary>Raw HTML details</summary>

Hidden *markdown* content.

</details>

<script>document.body.innerHTML = 'XSS'</script>
