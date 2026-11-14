# site

The public site (LINK-4, CMP-5): plain HTML and CSS, no build step. Serve this folder at the
root of the link host (PRD 9.1 step 6), for example a GitHub Pages user site.

- `index.html`: what Waypoints is.
- `404.html`: the landing page for every shared link (`/profile/<id>`, `/car/<id>`,
  `/meet/<id>`, `/team/<id>`, `/listing/<id>`, `/post/<id>`, `/invite/team/<code>`,
  `/invite/convoy/<code>`). Hosts like GitHub Pages serve it for any path with no file; it reads
  `location.pathname` and says what the link is and where to get Waypoints.
- `terms.html`, `privacy.html`: served as `/terms` and `/privacy` (S6 links there).
- `.well-known/apple-app-site-association`: universal links. Replace `TEAMID` with the Apple
  developer Team ID before publishing. Served over https at the host root, no redirects.
- `.nojekyll`: stops GitHub Pages dropping `.well-known`.

Then set `LINK_HOST` in `ios/App/Config.xcconfig` to the same host (bare, no scheme).
