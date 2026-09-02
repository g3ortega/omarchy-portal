.pragma library

// Brand hexes are fixed; themes are not. An icon color only gets used when it
// actually reads against the live popup surface — otherwise the theme
// foreground steps in. WCAG relative luminance, pragmatic 2:1 floor for
// glyph-sized marks.

function _chan(c) {
  c = c / 255
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
}

function _lum(r, g, b) {
  return 0.2126 * _chan(r) + 0.7152 * _chan(g) + 0.0722 * _chan(b)
}

function _lumHex(hex) {
  var h = String(hex).replace("#", "")
  if (h.length !== 6) return null
  return _lum(parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16))
}

// bg is a QML color (has .r/.g/.b in 0..1).
function contrast(hex, bg) {
  var l1 = _lumHex(hex)
  if (l1 === null) return 0
  var l2 = _lum(bg.r * 255, bg.g * 255, bg.b * 255)
  return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)
}

function readable(hex, bg) { return contrast(hex, bg) >= 2.0 }

// The glyph tint for an entry: its brand color when brand colors are on and
// the color reads against the surface, else the theme foreground.
function iconColor(entry, brand, bg, fallback) {
  return brand && entry && entry.color && readable(entry.color, bg) ? entry.color : fallback
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { readable: readable, contrast: contrast, iconColor: iconColor }
}
