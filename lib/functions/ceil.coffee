exports.fn = (n) -> 
  n = Number(n) unless n.constructor is Number
  Math.ceil(n)