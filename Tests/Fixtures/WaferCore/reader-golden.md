# Reader Golden

Opening paragraph with **strong text**, *emphasis*, ~~removed words~~, `inline code`, a [reference link](https://example.com/docs), and <kbd>Cmd</kbd> + <kbd>K</kbd>.

Bare URL for autolink coverage: https://example.org/golden.

## Duplicate Section

> A blockquote with **formatting** and `inline code`.

## Duplicate Section

- [x] Capture the first task
- [ ] Leave the second task open
  - [x] Nested task stays nested

@Note {
Remember that notes can carry normal **markdown**.
}

@Tip(title: "Shortcut") {
Use <kbd>Return</kbd> to accept the focused result.
}

@Important {
Important context belongs near the decision.
}

@Warning(title: "Careful") {
Warnings keep their custom labels.
}

@Caution {
Caution text stays readable.
}

| Feature | Status | Notes |
| --- | ---: | --- |
| Library | 7 | Folder tree and quick open |
| Export | 8 | Themed HTML and PDF |
| Preview | 9 | Scriptless Quick Look |

```swift
struct GoldenReader {
    let title = "Stable"
}
```

```json
{
  "theme": "dark",
  "stable": true
}
```

<details><summary>Raw HTML</summary><p>Allowed subset stays visible.</p></details>

---

Final paragraph with duplicate heading anchors above.
