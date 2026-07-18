-- Run with:
--   LUA_PATH="./?.lua;./plugins/dynamic-upstream/?.lua;;" lua spec/run.lua
require "spec.template_spec"
require "spec.rules_spec"
require "spec.schema_spec"
require("spec.test_helper").finish()
