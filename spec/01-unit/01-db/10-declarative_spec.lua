require("spec.helpers") -- for kong.log
local declarative = require "kong.db.declarative"
local conf_loader = require "kong.conf_loader"
local Schema = require "kong.db.schema"

local null = ngx.null


describe("declarative", function()
  describe("parse_string", function()
    it("converts lyaml.null to ngx.null", function()
      local dc = declarative.new_config(conf_loader())
      local entities, err = dc:parse_string [[
_format_version: "1.1"
routes:
  - name: null
    paths:
    - /
]]
      assert.equal(nil, err)
      local _, route = next(entities.routes)
      assert.equal(null,   route.name)
      assert.same({ "/" }, route.paths)
    end)
  end)

  it("ttl fields are accepted in DB-less schema validation", function()
    local dc = declarative.new_config(conf_loader())
    local entities, err = dc:parse_string([[
_format_version: '2.1'
consumers:
- custom_id: ~
  id: e150d090-4d53-4e55-bff8-efaaccd34ec4
  tags: ~
  username: bar@example.com
services:
keyauth_credentials:
- created_at: 1593624542
  id: 3f9066ef-b91b-4d1d-a05a-28619401c1ad
  tags: ~
  ttl: ~
  key: test
  consumer: e150d090-4d53-4e55-bff8-efaaccd34ec4
]])
    assert.equal(nil, err)

    assert.is_nil(entities.keyauth_credentials['3f9066ef-b91b-4d1d-a05a-28619401c1ad'].ttl)
  end)


  describe("schemas_topological_sort", function()

    local function collect_names(schemas)
      local names = {}
      for i = 1, #schemas do
        names[i] = schemas[i].name
      end
      return names
    end


    local function schema_new(s)
      return assert(Schema.new(s))
    end

    local ts = declarative._schemas_topological_sort

    it("sorts an array of unrelated schemas alphabetically by name", function()
      local a = schema_new({ name = "a", fields = { { a = { type = "string" } } } })
      local b = schema_new({ name = "b", fields = { { b = { type = "boolean" } } } })
      local c = schema_new({ name = "c", fields = { { c = { type = "integer" } } } })

      local x = ts({ a, b, c })
      assert.same({"c", "b", "a"},  collect_names(x))
    end)

    it("it puts destinations first", function()
      local a = schema_new({ name = "a", fields = { { a = { type = "string" } } } })
      local c = schema_new({
        name = "c",
        fields = {
          { c = { type = "integer" }, },
          { a = { type = "foreign", reference = "a" }, },
        }
      })
      local b = schema_new({
        name = "b",
        fields = {
          { b = { type = "boolean" }, },
          { a = { type = "foreign", reference = "a" }, },
          { c = { type = "foreign", reference = "c" }, },
        }
      })

      local x = ts({ a, b, c })
      assert.same({"a", "c", "b"},  collect_names(x))
    end)

    it("puts core entities first, even when no relations", function()
      local a = schema_new({ name = "a", fields = { { a = { type = "string" } } } })
      local routes = schema_new({ name = "routes", fields = { { c = { type = "boolean" } } } })

      local x = ts({ a, routes })
      assert.same({"routes", "a"},  collect_names(x))
    end)

    it("puts workspaces before core and others, when no relations", function()
      local a = schema_new({ name = "a", fields = { { a = { type = "string" } } } })
      local workspaces = schema_new({ name = "workspaces", fields = { { w = { type = "boolean" } } } })
      local routes = schema_new({ name = "routes", fields = { { r = { type = "boolean" } } } })

      local x = ts({ a, routes, workspaces })
      assert.same({"workspaces", "routes", "a"},  collect_names(x))
    end)

    it("puts workspaces first, core entities second, and other entities afterwards, even with relations", function()
      local a = schema_new({ name = "a", fields = { { a = { type = "string" } } } })
      local services = schema_new({ name = "services", fields = {} })
      local b = schema_new({
        name = "b",
        fields = {
          { service = { type = "foreign", reference = "services" }, },
          { a = { type = "foreign", reference = "a" }, },
        }
      })
      local routes = schema_new({
        name = "routes",
        fields = {
          { service = { type = "foreign", reference = "services" }, },
        }
      })
      local workspaces = schema_new({
        name = "workspaces",
        fields = { { b = { type = "boolean" } } }
      })
      local x = ts({ services, b, a, workspaces, routes })
      assert.same({ "workspaces", "services", "routes", "a", "b" },  collect_names(x))
    end)

    it("overrides core order if dependencies force it", function()
      -- This scenario is here in case in the future we allow plugin entities to precede core entities
      -- Not applicable today (kong 2.3.x) but maybe in future releases
      local a = schema_new({ name = "a", fields = { { a = { type = "string" } } } })
      local services = schema_new({ name = "services", fields = {
        { a = { type = "foreign", reference = "a" } } -- we somehow forced services to depend on a
      }})
      local workspaces = schema_new({ name = "workspaces", fields = {
        { a = { type = "foreign", reference = "a" } } -- we somehow forced workspaces to depend on a
      } })

      local x = ts({ services, a, workspaces })
      assert.same({ "a", "workspaces", "services" },  collect_names(x))
    end)

    it("returns an error if cycles are found", function()
      local a = schema_new({
        name = "a",
        fields = {
          { a = { type = "string" }, },
          { b = { type = "foreign", reference = "b" }, },
        }
      })
      local b = schema_new({
        name = "b",
        fields = {
          { b = { type = "boolean" }, },
          { a = { type = "foreign", reference = "a" }, },
        }
      })
      local x, err = ts({ a, b })
      assert.is_nil(x)
      assert.equals("Cycle detected, cannot sort topologically", err)
    end)
  end)
end)
