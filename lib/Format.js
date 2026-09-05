.pragma library

// Shared human formatting for bytes and uptime. Plain-node loadable like
// Detect.js.

function bytesKb(kb) {
  if (kb === undefined || kb === null) return ""
  var m = Math.round(kb / 1024)
  if (m >= 1024) return (kb / 1048576).toFixed(1) + "G"
  if (Math.round(kb) >= 1024) return m + "M"
  return Math.round(kb) + "K"
}

function uptime(sec) {
  if (sec === undefined || sec === null) return ""
  if (sec >= 86400) return Math.floor(sec / 86400) + "d"
  if (sec >= 3600) return Math.floor(sec / 3600) + "h"
  if (sec >= 60) return Math.floor(sec / 60) + "m"
  return sec + "s"
}

// A duration in the coarsest unit that keeps one significant figure.
function span(sec) {
  if (sec < 60) return Math.round(sec) + "s"
  if (sec < 3600) return Math.round(sec / 60) + "m"
  return (sec / 3600).toFixed(1) + "h"
}

function uptimeLine(sec) {
  if (sec === undefined || sec === null) return ""
  return (sec >= 86400 ? "still alive · " : "up ") + uptime(sec)
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { bytesKb: bytesKb, uptime: uptime, uptimeLine: uptimeLine, span: span }
}
