# Source Code Tour Pt.3

This week we’ll look at two connected systems:
how components are defined, and how the frontend becomes hydrated with only the components it needs.

## Components
All components live in a single components directory. Since the project takes a *vanilla-first* approach, each component is a standard Web Component defined in a standalone HTML file. Each file contains its template, styling, and logic together:
```html
&lt;template id="my-component-template">
  &lt;style>
  ...
  &lt;/style>
  ...
&lt;/template>

&lt;script>
  class MyComponent extends HTMLElement {
    connectedCallback() {
        ...
    }
  }

  customElements.define('my-component', MyComponent);
&lt;/script>
```
The only requirement is that the `<template>` element must have an ID matching the component name with "-template" appended. For example:

* Component name: `my-component`

* Template ID: `my-component-template`

As long as a file like this exists in the components directory, the server treats it as an available component, ready to be shipped to the client if needed.
## Tracking Hydrated Components (x-hydrated)
To avoid re-sending components the client already has, the server needs to know which ones the browser has loaded. The browser sends this information automatically before each HTMX request.
Here’s the snippet from `index.html` that handles this:
```javascript
document.body.addEventListener("htmx:beforeRequest", (event) => {
      const children = document.querySelector("#components-cache").children;
      const set = new Set();
      for (const el of children) {
        if (el instanceof HTMLScriptElement) {
          continue;
        }
        const cleanName = el.id.replace(/-template$/, "");
        if (cleanName.trim().length > 0) {
          set.add(cleanName);
        }
      }
      event.detail.xhr.setRequestHeader("x-hydrated", JSON.stringify([...set]))
});
```
The client keeps all received components inside a special section:
```html
<section id="components-cache"> </section>
```

Before any HTMX request, the browser:

1. Scans the cache

2. Collects the names of all components it already has

3. Sends them in the `x-hydrated` header

This ensures the server only sends the components the client is missing.

## How the Server Builds a Response

Now that we understand what a component is, and how the client reports which components it has, we can look at how the server uses that information to construct a response.

Most servers follow a pattern like:

1. Router matches a path

2. Router hands full control to the handler

3. Handler returns a string/struct/stream

4. Router wraps it in HTTP and sends it

In this model, the handler decides everything.

My server keeps control of the entire response.
Route handlers don’t return HTML, they write HTML into a writer the router owns. Here’s the control flow:

1. Router matches a path

2. Router gives the handler a writer + the request

3. Handler writes raw HTML into the writer

4. Router reads the `x-hydrated` header → which components the client already has

5. Router scans the HTML in the writer → which components the page uses

6. Router calculates the difference

7. Router adds a `<section id="components-cache">` containing the components the client is missing. The `hx-swap-oob` attribute controls how the client applies them: appended when navigating via HTMX, replaced when the page is loaded fresh.

8. Router sends the final HTML to the client

This architecture asks that route handlers only generate HTML so that the router can manage component inclusion.

## Why?
Writing this logic and doing the upfront work has a big payoff when working on the site. I can define or debug a component entirely within a single HTML file, and I can freely use any component I need without worrying about manually including it. The server automatically figures out which components to send. An additional benefit is efficiency: the server only sends the components the client actually needs, minimizing network overhead.

Thanks for reading this week's post and happy thanksgiving :) 
