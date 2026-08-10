local typedecl = require "titan-compiler.typedecl"

describe("typedecl", function()

    it("creates a constructor for a type", function()
        local types = {
            CategoryA = {
                Node1 = { "field1", "field2" }
            }
        }
        local constructors = typedecl("Prefix", types)

        assert.is_function(constructors.Node1)

        local node = constructors.Node1("value1", "value2")
        assert.same("Prefix.Node1", node._tag)
        assert.same("value1", node.field1)
        assert.same("value2", node.field2)
    end)

    it("throws an error when called with wrong number of arguments", function()
        local types = {
            CategoryA = {
                Node1 = { "field1", "field2" }
            }
        }
        local constructors = typedecl("Prefix", types)

        assert.has_error(function()
            constructors.Node1("value1")
        end, "missing arguments for Node1")

        assert.has_error(function()
            constructors.Node1("value1", "value2", "value3")
        end, "missing arguments for Node1")
    end)

    it("handles multiple categories and multiple types", function()
        local types = {
            CategoryA = {
                Node1 = { "field1" },
            },
            CategoryB = {
                Node2 = { "fieldA", "fieldB" },
                Node3 = {}
            }
        }
        local constructors = typedecl("Prefix", types)

        local node1 = constructors.Node1("val")
        assert.same("Prefix.Node1", node1._tag)
        assert.same("val", node1.field1)

        local node2 = constructors.Node2("valA", "valB")
        assert.same("Prefix.Node2", node2._tag)
        assert.same("valA", node2.fieldA)
        assert.same("valB", node2.fieldB)

        local node3 = constructors.Node3()
        assert.same("Prefix.Node3", node3._tag)
    end)
end)
