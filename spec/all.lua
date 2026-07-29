-- Entry point for `make test`. Run from the repository root.
--
-- The plugin directory is put on package.path exactly the way KOReader's
-- pluginloader does it, so the specs require modules by the same names the
-- plugin itself uses.
package.path = "./?.lua;./karako.koplugin/?.lua;" .. package.path

local Runner = require("spec.runner")

require("spec.articleutil_spec")
require("spec.config_spec")
require("spec.epubbuilder_spec")

os.exit(Runner.report() and 0 or 1)
