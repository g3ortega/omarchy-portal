.pragma library

var ranges = [
  { label: "30m", seconds: 1800 }, { label: "1h", seconds: 3600 },
  { label: "3h", seconds: 10800 }, { label: "6h", seconds: 21600 },
  { label: "1d", seconds: 86400 }, { label: "2d", seconds: 172800 }
]
var fields = ["latMs", "conns", "cpuPct", "rssKb"]

function aggregate(samples, seconds, end, maxBuckets) {
  var start = end - seconds
  var size = seconds / (maxBuckets || 400)
  var bins = {}, stats = {}, count = 0, first = null, last = null
  for (var f = 0; f < fields.length; f++) stats[fields[f]] = { lo: null, hi: null }
  for (var i = 0; i < samples.length; i++) {
    var sample = samples[i]
    if (sample.t < start || sample.t > end) continue
    var index = Math.min((maxBuckets || 400) - 1, Math.floor((sample.t - start) / size))
    var bucket = bins[index]
    if (!bucket) {
      bucket = { t: start + index * size, end: Math.min(end, start + (index + 1) * size), count: 0 }
      for (var k = 0; k < fields.length; k++) bucket[fields[k]] = { lo: null, hi: null, avg: null, count: 0 }
      bins[index] = bucket
    }
    bucket.count++
    count++
    first = first === null ? sample.t : Math.min(first, sample.t)
    last = last === null ? sample.t : Math.max(last, sample.t)
    for (var j = 0; j < fields.length; j++) {
      var field = fields[j], value = sample[field]
      if (value === null || value === undefined) continue
      var metric = bucket[field], bounds = stats[field]
      metric.avg = ((metric.avg || 0) * metric.count + value) / (metric.count + 1)
      metric.count++
      metric.lo = metric.lo === null ? value : Math.min(metric.lo, value)
      metric.hi = metric.hi === null ? value : Math.max(metric.hi, value)
      bounds.lo = bounds.lo === null ? value : Math.min(bounds.lo, value)
      bounds.hi = bounds.hi === null ? value : Math.max(bounds.hi, value)
    }
  }
  return { start: start, end: end, bucketSeconds: size, count: count, first: first, last: last,
           buckets: Object.keys(bins).map(function (key) { return bins[key] }), stats: stats }
}

function bucketAt(view, time) {
  for (var i = 0; i < view.buckets.length; i++) {
    var b = view.buckets[i]
    if (time >= b.t && (time < b.end || time === view.end && b.end === view.end)) return i
  }
  return -1
}

function connected(previous, current, field) {
  return previous !== null && Math.abs(previous.end - current.t) < 0.00001
    && previous[field].count === previous.count && current[field].count === current.count
    && previous[field].count > 0 && current[field].count > 0
}
