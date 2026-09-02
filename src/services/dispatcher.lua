Dispatcher = {}

local function cap(d)
  return math.max(0, d.capacity or 0) * math.max(0, d.weight or 1)
end
local function available(d) return d.available ~= false end
local function deadband(raw, old, capacity, threshold)
  if old == nil or raw == 0 or raw == capacity then return raw end
  if math.abs(raw - old) < capacity * (threshold or 0) then return old end
  return raw
end

function Dispatcher.allocate(input, config)
  config = config or {}
  local reactors, turbines = {}, {}
  local sources, total = {}, 0
  for _, d in ipairs(input.passiveReactors or {}) do
    if available(d) then local c=cap(d); sources[#sources+1]={d=d,c=c}; total=total+c end
  end
  for _, d in ipairs(input.turbines or {}) do
    if available(d) then local c=cap(d); sources[#sources+1]={d=d,c=c}; total=total+c end
    end
  local required = math.max(0, input.requiredRF or 0)
  local utilization = total > 0 and math.min(1, required / total) or 0
  local previous = input.previousTargets or {}
  local threshold = config.dispatchRebalanceThreshold or 0.02
  for _, s in ipairs(sources) do
    local d, raw = s.d, s.c * utilization
    if d.maxFlow then
      local rf = raw
      local old = previous.turbines and previous.turbines[d.id]
      local oldrf = type(old)=="table" and old.rfTarget or old
      rf = deadband(rf, oldrf, d.capacity or 0, threshold)
      local flow = d.rfPerSteam and math.min(d.maxFlow, rf / d.rfPerSteam) or 0
      turbines[d.id] = {rfTarget=rf, flowTarget=flow, maxFlow=d.maxFlow,
        rpmLimit=config.sustainedOverspeedLimitRPM or 2400}
    else
      local old = previous.reactors and previous.reactors[d.id]
      reactors[d.id] = {unit="rf", target=deadband(raw, old, d.capacity or 0, threshold)}
    end
  end
  -- Steam demand is supplied by active reactors within each turbine group.
  local groups = {}
  for _, d in ipairs(input.turbines or {}) do if available(d) and d.groupId then
    local t=turbines[d.id]; groups[d.groupId]=(groups[d.groupId] or 0)+(t and t.flowTarget or 0)
  end end
  for id, g in pairs(input.steamGroups or {}) do groups[id]=(groups[id] or 0)+(g.steamCorrection or 0) end
  for _, d in ipairs(input.activeReactors or {}) do if available(d) then
    local group = d.groupId; local demand=math.max(0, groups[group] or 0)
    local members={}; for _, x in ipairs(input.activeReactors or {}) do if available(x) and x.groupId==group then members[#members+1]=x end end
    local sum=0; for _, x in ipairs(members) do sum=sum+cap(x) end
    local util=sum>0 and math.min(1,demand/sum) or 0
    local capacity=cap(d); local raw=capacity*util; local old=previous.reactors and previous.reactors[d.id]
    reactors[d.id]={unit="steam",target=deadband(raw,old,capacity,threshold)}
  end end
  return {reactors=reactors,turbines=turbines,requiredRF=required,availableRF=total,saturation=total>0 and required/total or 0}
end

function Dispatcher.learnCapacity(previous, observation, config)
  observation=observation or {}; config=config or {}
  if observation.configured then return {value=observation.configured,known=true,misses=0} end
  previous=previous or {value=math.max(1,observation.actual or 0),known=false,misses=0}
  local result={value=previous.value,known=previous.known,misses=previous.misses or 0}
  if observation.transient or not observation.steady then return result end
  local actual,target=math.max(0,observation.actual or 0),math.max(0,observation.target or 0)
  local ceiling=observation.ceiling or math.huge; local alpha=config.capacityLearningRate or 0.05
  if target>0 and actual>=target*0.95 then result.value=math.min(ceiling,result.value+alpha*(math.max(actual,target)-result.value)); result.misses=0
  elseif target>result.value*0.9 and actual<target*0.8 then result.misses=result.misses+1; if result.misses>=3 then result.value,result.misses=math.max(1,actual),0 end end
  result.known=previous.known or actual>0; return result
end
