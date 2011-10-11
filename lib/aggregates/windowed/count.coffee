support = require('./../../support')

class Count

  constructor: (@args) ->
    @count = 0
    throw new Error("COUNT() should only be called with one argument") unless @args.length is 1
    @field = @args[0]
    
  insert: (record) ->
    val = support.valueForField(@field, record)
    val = Number(val) unless typeof val is 'number'
    @count += val
    @count
  
  remove: (record) ->
    val = support.valueForField(@field, record)
    val = Number(val) unless typeof val is 'number'
    @count -= val
    @count
  
exports.fn = Count