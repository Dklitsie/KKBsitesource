# Source Code Tour Pt.2
This week I’m diving into the frontend side of the site, and `index.html` is the best place to start. Here’s the full file so you can see how the pieces fit together.
#### The Code

```html
&lt;!DOCTYPE html>
&lt;html lang="en">

&lt;head>
  &lt;meta charset="UTF-8">
  &lt;meta name="viewport" content="width=device-width, initial-scale=1.0">

  &lt;script src="https://unpkg.com/htmx.org@2.0.4">&lt;/script>
  &lt;script type="module" src="https://md-block.verou.me/md-block.js">&lt;/script>
  &lt;link href="styles/prism.css" rel="stylesheet">
  &lt;script src="scripts/prism.js">&lt;/script>

  &lt;link rel="stylesheet" href="styles/crt.css">
  &lt;link rel="stylesheet" href="styles/global.css">

  &lt;title>voidkandy.space&lt;/title>

  &lt;style>
    #frame {
            display: flex;
            flex-direction: column;
            background-color: light-dark(var(--light-bg), var(--dark-bg));
            z-index: 2;
            align-content: center;
            justify-content: space-between;
            min-width: 80vw;
            min-height: 100vh;
    }

    #route-content {
            display: flex;
            flex-grow: 1;
            overflow-y: auto;
            overflow-x: hidden;
            height: 100%;
    }

    nav-router button {
            background-color: var(--primary-orange);
            filter: saturate(500%);
    }
  &lt;/style>
&lt;/head>

&lt;body class="crt">
    &lt;script>
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
    &lt;/script>
    &lt;div id="frame" class="box">
            &lt;div style="display:flex; flex-direction: column; flex-grow: 1;">
              &lt;div style="display: flex;
                          flex-direction:row;
                          justify-content:space-between;
                          padding-bottom: 1rem;
                          border-bottom: 1px dashed;
                          border-color: light-dark(var(--light-border), var(--dark-border));
                          ">
                &lt;nav-router routes="Home, Music, Info, Blog" target="#route-content"> &lt;/nav-router>
                &lt;dark-mode-button defaultDark="false" lightModeText="Dark Mode" darkModeText="Light Mode">
                &lt;/dark-mode-button>
            &lt;/div>
            &lt;div id="route-content">
              ||zz .hydration zz||
            &lt;/div>
          &lt;/div>
          &lt;div style="margin-top: 1rem;">
              &lt;color-squares> &lt;/color-squares>
          &lt;/div>
        &lt;/div>
&lt;/body>
&lt;/html>
```
### Minimum Dependency & Vanilla First
I've built sites using many frameworks; Rust with Askama, Go with templ, React, Sveltekit even Dioxus. When I set out to rebuild my portfolio I knew I wanted to take a minimal dependency, vanilla first approach. That meant avoiding extra JavaScript libraries on the frontend and keeping Zig dependencies to a minimum on the backend. As you can see, I'm only importing three Javascript libraries: HTMX for frontend routing and md-block with prism-js for rendering these blog posts from markdown files. The vanilla-first approach also meant choosing plain CSS instead of frameworks like Bootstrap or Tailwind. All other interactivity is implemented through vanilla JS web components.

### Hand rolled Templating Engine
 You might notice a part of the code that looks like `||zz .hydration zz||`. This is template syntax for [the templating engine I wrote](https://github.com/voidKandy/zemplate) for this site. Anytime I use the templating engine, I associate some arbitrary zig struct with the template, anytime this is used it just means that a field of the struct is going to be inserted into the template. For example:
```zig
const MyContext = struct { my_field: []const u8 };
const MyTemplate = zemplate.Template(MyContext,
    \\Hello ||zz .my_field zz||!
);
var tmplt = MyTemplate.init(MyContext{ .field = "World" }, allocator);
var render = try tmplt.render();
std.debug.print("{s}",.{render.items});
```
The above program would print "Hello World!". This templating engine is used all over this site.


#### Hydration
Hydration is where the site really comes together. This is where the HTML for the current route gets inserted.

For example, you’re currently at:
```
voidkandy.space/Blog?post=the-name-of-this-blog-post
```
The server generates the HTML for that route and inserts it into the `#route-content` div. Before each HTMX request, a tiny inline script collects all components currently on the page and sends their names in an **x-hydrated** header. The backend knows which components the requested page needs, compares them with the header, and sends only the missing ones. This is how the site stays “hydrated” without ever loading the same component twice.
I’ll also go deeper into how routing and hydration work on the serverside in another post.

#### Components
Each component lives in a standalone HTML file inside the components directory. These files contain the template, styling, and JS logic in one place. Here’s one example:
```html
&lt;template id="dark-mode-button-template">
  &lt;button id="dark-mode-button" class="crt">&lt;/button>
&lt;/template>

&lt;script>
  class DarkModeButton extends HTMLElement {
    connectedCallback() {

          const template = document.getElementById('dark-mode-button-template').content.cloneNode(true);
          this.appendChild(template);
          this.button = this.querySelector("#dark-mode-button");

          if (localStorage.getItem('dark') === null) {
            localStorage.setItem('dark', this.defaultDark ? "true" : "false");
          }

          this.button.textContent = this.darkIsSet ? this.darkModeText : this.lightModeText;

          this.button.addEventListener('click', () => {
            this.toggleDarkMode();
            this.button.textContent = this.darkIsSet ? this.darkModeText : this.lightModeText;
          });

          this.applyDarkMode();
    }

    get defaultDark() {
            return this.getAttribute('defaultDark') === 'true';
    }

    get lightModeText() {
            return this.getAttribute('lightModeText') || 'Light Mode!';
    }

    get darkModeText() {
            return this.getAttribute('darkModeText') || 'Dark Mode!';
    }

    get darkIsSet() {
            return localStorage.getItem('dark') === "true";
    }

    applyDarkMode() {
            if (this.darkIsSet) {
              document.body.classList.add("dark");
            } else {
              document.body.classList.remove("dark");
            }
    }

    toggleDarkMode() {
            if (this.darkIsSet) {
              document.body.classList.remove("dark");
              localStorage.setItem('dark', "false");
            } else {
              document.body.classList.add("dark");
              localStorage.setItem('dark', "true");
            }
    }
  }

  customElements.define('dark-mode-button', DarkModeButton);
&lt;/script>
```
We don’t need to go into its specifics here, but this is how components are included. I have made a rule that components' templates id must match the name of the component as it is defined just with "-template" at the end. The server watches these files for changes so they can be hot-reloaded during development. There’s no extra work needed to register them; if a component exists as an HTML file in the components directory, it’s available on the frontend. 
I’ll cover how hot reloading and component handling work on the backend in a future post.



### CSS
To close, lets take a look at the `global.css` file:
```css
:root {
  color-scheme: light dark;
  --offwhite: #dacebf;
  --offblack: #333333;

  --light-bg: #d1c4b6;
  --light-color: #2c2c2c;
  --light-border: #000000;
  --light-button: #d1c4b6;


  --dark-bg: #2c2c2c;
  --dark-color: #d1c4b6;
  --dark-border: #e8dcd3;
  --dark-button: #2c2c2c;

  --primary-orange: #fdb571;
  --secondary-red: #E3174A;
  --tertiary-blue: #69a2b0;
  --box-shadow-color: var(--light-border);
}

.dark {
  color-scheme: dark !important;
  --box-shadow-color: var(--dark-border);
}

body {
  font-family: Andale Mono, monospace;
  background-color: light-dark(var(--light-bg), var(--dark-bg));
  color: light-dark(var(--light-color), var(--dark-color));
  margin: 0;
  padding: 0;
  display: flex;
  justify-content: center;
  align-items: center;
  color-scheme: light;
}

...

@media (max-width: 930px) {
  ...
}
```
I’ve left out most of the file and replaced it with ellipses; we don’t need to dive into every rule. The key points:
+ All commonly used colors are defined in `:root`.
+ I’m using the vanilla browser feature light-dark to handle light and dark themes. This limits theme changes to color and background-color, but it’s a helpful constraint.
+ Finally, the media query shows how I make pages responsive.

Thanks for reading, next week I'll be going over how the backend works with HTMX.
