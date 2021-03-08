local protoc = require "protoc"
local pb = require "pb"
require "lua_pack"

local Rpc = {}
Rpc.__index = Rpc

--local pp = require "pl.pretty".write





local pb_unwrap
do
  local structpb_value, structpb_list, structpb_struct

  function structpb_value(v)
    if v.list_value then
      return structpb_list(v.list_value)
    end

    if v.struct_value then
      return structpb_struct(v.struct_value)
    end

    return v.bool_value or v.string_value or v.number_value or v.null_value
  end

  function structpb_list(l)
    local out = {}
    for i, v in ipairs(l.values or l) do
      out[i] = structpb_value(v)
    end
    return out
  end

  function structpb_struct(v)
    return v
  end

  pb_unwrap = {
    [".google.protobuf.Value"] = structpb_value,
    [".google.protobuf.ListValue"] = structpb_list,
    [".google.protobuf.Struct"] = structpb_struct,
    [".kong_plugin_protocol.KV"] = function(d)
      return {d.k, structpb_value(d.v)}
    end,
    [".kong_plugin_protocol.ExitArgs"] = function (d)
      return {d.status, d.body, d.headers}
    end,
  }
end

local pb_wrap = {}


local function index_table(table, field)
  if table[field] then
    return table[field]
  end

  local res = table
  for segment, e in ngx.re.gmatch(field, "\\w+", "o") do
    if res[segment[0]] then
      res = res[segment[0]]
    else
      return nil
    end
  end
  return res
end

local function load_service()
  local exposed_api = {
    kong = kong,
  }

  local p = protoc.new()
  --p:loadfile("kong/pluginsocket.proto")

  p:addpath("/usr/include")
  local parsed = p:parsefile("kong/pluginsocket.proto")

  local service = {}
  for i, s in ipairs(parsed.service) do
    for j, m in ipairs(s.method) do
      local method_name = s.name .. '.' .. m.name
      local lower_name = m.options and m.options.options and m.options.options.MethodName
          or method_name:gsub('_', '.'):gsub('([a-z])([A-Z])', '%1_%2'):lower()

      service[lower_name] = {
        method_name = method_name,
        method = index_table(exposed_api, lower_name),
        input_type = m.input_type,
        output_type = m.output_type,
      }
      --print(("rpc_service[%q] = %s"):format(lower_name, pp(rpc_service[lower_name])))
    end
  end

  p:loadfile("google/protobuf/empty.proto")
  p:loadfile("google/protobuf/struct.proto")
  p:loadfile("kong/pluginsocket.proto")

  return service
end



local rpc_service


local function identity_function(...)
  return ...
end


local function call_pdk(method_name, arg)
  local method = rpc_service[method_name]
  --kong.log.debug("method ", method_name, ": ", pp(method))
  if not method then
    return nil, ("method %q not found"):format(method_name)
  end

  arg = assert(pb.decode(method.input_type, arg))
  --kong.log.debug("args decoded: ", pp(arg))
  local unwrap = pb_unwrap[method.input_type] or identity_function
  local wrap = pb_wrap[method.output_type] or identity_function

  local reply = wrap(method.method(table.unpack(unwrap(arg))))
  if reply == nil then
    --kong.log.debug("no reply")
    return ""
  end

  --kong.log.debug("reply wrapped: ", pp(reply))
  reply = assert(pb.encode(method.output_type, reply))

  return reply
end


local function read_frame(c)
  --kong.log.debug("reading frame...")
  local msg, err = c:receive(4)   -- uint32
  if not msg then
    return nil, err
  end
  local _, msg_len = string.unpack(msg, "I")
  --kong.log.debug("len: ", msg_len)

  msg, err = c:receive(msg_len)
  if not msg then
    return nil, err
  end
  --kong.log.debug(("data: %q"):format(msg))

  return msg, nil
end

local function write_frame(c, msg)
  assert (c:send(string.pack("I", #msg)))
  assert (c:send(msg))
end

function Rpc.new(socket_path, notifications)

  if not rpc_service then
    rpc_service = load_service()
  end

  --kong.log.debug("pb_rpc.new: ", socket_path)
  return setmetatable({
  socket_path = socket_path,
  msg_id = 0,
  notifications_callbacks = notifications,
  }, Rpc)
end


function Rpc:call(method, data, do_bridge_loop)
  self.msg_id = self.msg_id + 1
  local msg_id = self.msg_id
  local c, err = assert(ngx.socket.connect("unix:" .. self.socket_path))

  msg_id = msg_id + 1
  --kong.log.debug("will encode: ", pp{sequence = msg_id, [method] = data})
  local msg = assert(pb.encode(".kong_plugin_protocol.RpcCall", {
    sequence = msg_id,
    [method] = data,
  }))
  --kong.log.debug("encoded len: ", #msg)
  assert (c:send(string.pack("I", #msg)))
  assert (c:send(msg))

  while do_bridge_loop do
    local method_name
    method_name, err = read_frame(c)
    if not method_name then
      return nil, err
    end
    if method_name == "" then
      break
    end

    --kong.log.debug(("pdk method: %q (%d)"):format(method_name, #method_name))

    local args
    args, err = read_frame(c)
    if not args then
      return nil, err
    end

    local reply
    reply, err = call_pdk(method_name, args)
    if not reply then
      return nil, err
    end

    err = write_frame(c, reply)
    if err then
      return nil, err
    end
  end

  msg, err = read_frame(c)
  if not msg then
    return nil, err
  end
  c:setkeepalive()

  msg = assert(pb.decode(".kong_plugin_protocol.RpcReturn", msg))
  --kong.log.debug("decoded: "..pp(msg))
  assert(msg.sequence == msg_id)

  return msg
end



return Rpc
