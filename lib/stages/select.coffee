events = require("events")
stages = require('../stages')
nodes = require('sql-parser').nodes
{Field} = require('../field')
{BaseStage} = require('./base')


# Select
# ---------
# This is the main Stage in a query
# it's responsible for selecting and manipulating data
# however alomst all of the work is done by many smaller stages.
# Selects are somewhat recursive as one can be fed by a SubSelect.
# By breaking selects down into many small steps things are
# conceptially simpler and we avoid blocking the event loop
# for long code paths.
exports.Select = class Select extends BaseStage
  
  constructor: (@context, @query) ->
    @context.streamManager
    @source = @query.source
    @build()
  
  # Proxy all inserts into the root node
  # the root node will either be a Listen
  # or a SubSelect stage.
  insert: (data) -> @root.insert(data)
  remove: (data) -> @root.remove(data)
  insertRemove: (i,r) -> @root.insertRemove(i,r)
  
  # This is the real meat of River, here we decide what stages a 
  # Select needs to go through to produce the required output.
  #
  # Breaking qeueries down into stages with events flowing between them
  # is a nice way to break a complex problem down into simple steps.
  #
  # Stages get bound together as a chain of events `@lastStage` is
  # used to track where the tail of this chain is so we can easily add
  # more Stages to the end of a plan.
  build: ->
    @fields = Field.fieldListFromNodes(@context, @query.fields, @isWindowed())
    @lastStage = @addSource()
    @addMinifier()
    @addRepeater() if @isWindowed()
    @addJoins()
    @addUnions()
    @addFilter() if @query.where
    if @hasAggregation() then @addAggregation() else @addProjection()
    @addDistinct() if @query.distinct
    @addLimit() if @query.limit
    # The output stage is a specal case which bubbles the final events up to the `Query`
    @output = new stages.Output(@context)
    @output.on 'insert', (newValues) => @emit('insert', newValues)
    @output.on 'remove', (oldValues) => @emit('remove', oldValues)
    @lastStage.pass(@output)
  
  # The root Stage for a query will either be a Listen
  # or a SubSelect. Depending on the source.
  addSource: ->
    @root = new stages.Source(@context, @source)
      
  # Minifiers take the insert stream and strip out fields
  # that aren't needed by the query.
  addMinifier: ->
    minifier = new stages.Minifier(@context, @query)
    @lastStage = @lastStage.pass(minifier)
  
  # Repeaters only get used when the `Query` is windowed.
  # They take the insert stream, stash it away, and then 
  # replay it on the remove stream once the conditions are met.
  addRepeater: ->
    if @source.winFn is 'length'
      repeater = new stages.LengthRepeater(@context, @source)
    else
      repeater = new stages.TimeRepeater(@context, @source)
    @lastStage = @lastStage.pass(repeater)
  
  # Joins connect sources together they hold in memory indexes
  # so that records between sources can be matched up.
  # Most queries have an empty `joins` array so this is a no-op.
  addJoins: ->
    first = true
    for join in @query.joins
      join = new stages.Join(@context, join, @root, first, @isWindowed())
      first = false
      @lastStage = @lastStage.pass(join)
  
  # Unions push the output of two queries on to the same 
  # insert and remove streams. Because we only support
  # UNION ALL and not UNION he queries are completely
  # independant so we simply setup the UNION ALL queries 
  # and then forward their results.
  addUnions: ->
    for union in @query.unions
      unionSelect = new stages.Select(@context, union.query)
      throw new Error('UNIONs are only supported with UNION ALL') unless union.all
      unionSelect.on 'insert', (newValues) => @emit('insert', newValues)
      unionSelect.on 'remove', (oldValues) => @emit('remove', oldValues)
  
  # Filters handle the WHERE part of a query.
  # They compile the conditions and then only emit
  # on events that meet the conditions.
  addFilter: ->
    filter = new stages.Filter(@context, @query.where.conditions)
    @lastStage = @lastStage.pass(filter)
  
  # Aggregations take care of GROUP clauses and Agg Functions
  # like `COUNT`.
  # They collect and track the aggregations but only emit when
  # changes to computed values occur.
  addAggregation: ->
    store = new stages.Aggregation(@context, @fields, @query.group?.fields, @query.group?.having)
    @lastStage = @lastStage.pass(store)
  
  # Projections take a set of `Field` expressions and emit new
  # objects that contain the correctly computed and named values
  addProjection: ->    
    projection = new stages.Projection(@context, @fields)
    @lastStage = @lastStage.pass(projection)
  
  # Distincts take injest and insert stream and only
  # emit when a record that hasn't been seen before is found
  addDistinct: ->
    distinct = new stages.Distinct(@context)
    @lastStage = @lastStage.pass(distinct)
  
  # Limits only really make sense on non-windowed queries they stop
  # emitting insert events once the limit number has been reached.
  addLimit: ->
    limit = new stages.Limit(@context, @query.limit.value)
    @lastStage = @lastStage.pass(limit)
  
  stop: ->
    @root.stop()
  
  # Lists the fields that are aggregators.
  aggregatorFields: -> (f for f in @fields when f.isFunction() and !f.isUDF())
  
  # Returns true if any of the Fields are aggregations.
  hasAggregation: -> @aggregatorFields().length > 0
  
  # Returns true if the query runs over a window of any kind.
  isWindowed: -> !@reliesOnSubSelect() and @source.win isnt null
  
  # Given a source node decide if it's a subselect or a root.
  reliesOnSubSelect: -> @source.constructor is nodes.SubSelect