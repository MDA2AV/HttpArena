local vm = require("@lute/vm")
local task = require("@std/task")
local system = require("@std/system")

local cpuCount = system.threadCount() / 2

for _ = 1, cpuCount do
	task.spawn(vm.create("./serve").serve)
end

print(`Application started ({cpuCount} server threads).`)
