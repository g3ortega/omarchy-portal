.pragma library

// Every glyph Portal draws, declared by Nerd Font glyph name and codepoint.
//
// Two rules, both learned the hard way:
//
// 1. Never paste a raw Nerd Font character into source. Glyphs in the
//    U+F000-U+F8FF private-use range get silently dropped by some editors,
//    terminals, and copy-paste paths. The string becomes empty, the control
//    renders nothing, and nothing warns you -- not the compiler, not qmllint,
//    not the runtime.
//
// 2. Never trust a codepoint you have not resolved by name. A codepoint that
//    exists in the font is not necessarily the icon you meant: U+F0B0E is
//    md-alpha_g_box (a letter G in a box), not md-broadcast; U+F0C4 is
//    fa-scissors, not a package. The trailing comment on each line below is
//    the font's actual glyph name, and scripts/check-glyphs.sh asserts it
//    still matches the installed font.
//
// To add an icon: find its glyph name at nerdfonts.com/cheat-sheet, add the
// line, then run scripts/check-glyphs.sh.

var CP = {
  // Frameworks and languages
  next: 0x0E83E,            // dev-nextjs
  react: 0x0E7BA,           // dev-react
  vue: 0x0E8DC,             // dev-vuejs
  nuxt: 0x0E84B,            // dev-nuxtjs
  svelte: 0x0E8B7,          // dev-svelte
  angular: 0x0E753,         // dev-angular
  astro: 0x0E735,           // dev-astro
  vite: 0x0F0E7,            // fa-flash
  node: 0x0E718,            // dev-nodejs_small
  rails: 0x0E73B,           // dev-ruby_on_rails
  ruby: 0x0E739,            // dev-ruby
  python: 0x0E73C,          // dev-python
  django: 0x0E71D,          // dev-django
  go: 0x0F07D3,             // md-language_go
  rust: 0x0E7A8,            // dev-rust
  php: 0x0E73D,             // dev-php
  laravel: 0x0E73F,         // dev-laravel
  java: 0x0E738,            // dev-java
  elixir: 0x0E62D,          // seti-elixir
  dotnet: 0x0E77F,          // dev-dotnet

  // Data stores and infrastructure
  docker: 0x0E7B0,          // dev-docker
  postgres: 0x0E76E,        // dev-postgresql
  mysql: 0x0E704,           // dev-mysql
  redis: 0x0E76D,           // dev-redis
  elastic: 0x0E7CA,         // dev-elasticsearch
  database: 0xF01BC,        // md-database
  server: 0xF048B,          // md-server

  // Generic
  portal: 0xF0E95,          // md-circle_double
  globe: 0x0F0AC,           // fa-globe
  flask: 0x0F0C3,           // fa-flask
  package: 0xF03D6,         // md-package_variant
  cog: 0x0F013,             // fa-gear
  metrics: 0x0F0E93,        // md-chart_timeline_variant
  lock: 0x0F023,            // fa-lock

  // Charts
  watch: 0x0F06E,           // fa-eye
  unwatch: 0x0F070,         // fa-eye_slash
  back: 0x0F060,            // fa-arrow_left

  // Row actions
  open: 0x0F08E,            // fa-external_link
  copy: 0x0F0C5,            // fa-files_o
  stop: 0x0F04D,            // fa-stop
  refresh: 0x0F021,         // fa-refresh

  // Sharing reach
  broadcast: 0x0F1720,      // md-broadcast
  localRoute: 0xF0317,      // md-lan

}

function g(name) {
  var cp = CP[name]
  return cp === undefined ? "" : String.fromCodePoint(cp)
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { CP: CP, g: g }
}
