local CodeGen = {}
CodeGen.__index = CodeGen

function CodeGen.new()
    return setmetatable({
        assembly = {},     -- Array of generated assembly lines
        label_id = 0       -- Tracker to generate unique jump-labels
    }, CodeGen)
end

-- Append a line of assembly code
function CodeGen:emit(instr)
    table.insert(self.assembly, "  " .. instr)
end

-- Append a raw label definition (not indented)
function CodeGen:emit_label(label)
    table.insert(self.assembly, label .. ":")
end

-- Helper to generate unique branch labels
function CodeGen:next_label(prefix)
    self.label_id = self.label_id + 1
    return (prefix or "L") .. tostring(self.label_id)
end

-- Primary recursive generator
function CodeGen:generate(node)
    if node.type == "literal" then
        -- Return 6502 immediate syntax (e.g. #$0A)
        return "#$" .. string.format("%02X", node.value)

    elseif node.type == "variable" then
        -- Return 6502 Zero Page address syntax (e.g. $02)
        return "$" .. string.format("%02X", node.address)

    elseif node.type == "assignment" then
        -- Post-order check: Generate the value side first
        local val_src = self:generate(node.value)
        local target_addr = "$" .. string.format("%02X", node.target.address)

        -- If it's a binary op, the result is already sitting in accumulator 'A'
        if val_src ~= "A" then
            self:emit("LDA " .. val_src)
        end
        self:emit("STA " .. target_addr)

    elseif node.type == "binary_op" then
        local left = self:generate(node.left)
        local right = self:generate(node.right)

        if node.op == "+" then
            -- Load left-hand argument if it is not already sitting in accumulator
            if left ~= "A" then
                self:emit("LDA " .. left)
            end
            self:emit("CLC")
            self:emit("ADC " .. right)
            return "A" -- Inform parent node that result is sitting in Accumulator 'A'
        end

    elseif node.type == "if_statement" then
        -- Generate compare condition (assuming basic == right now)
        local left = self:generate(node.condition.left)
        local right = self:generate(node.condition.right)
        
        self:emit("LDA " .. left)
        self:emit("CMP " .. right)
        
        local skip_label = self:next_label("skip_if")
        self:emit("BNE " .. skip_label) -- Jump over if mismatch

        -- Generate block statements inside 'then'
        for _, stmt in ipairs(node.body) do
            self:generate(stmt)
        end

        self:emit_label(skip_label)
    end
end

-- Retrieve the fully compiled assembly source code
function CodeGen:get_code()
    return table.concat(self.assembly, "\n")
end

-- --- TEST DRIVE ---
local codegen = CodeGen.new()

-- Mock representation of AST for:
-- local x: u8 = 10
-- if x == 10 then x = x + 5 end
local mock_ast = {
    {
        type = "assignment",
        target = { address = 0x02 }, -- Zero Page $02
        target_type = "u8",
        value = { type = "literal", value = 10 }
    },
    {
        type = "if_statement",
        condition = {
            type = "binary_op",
            op = "==",
            left = { type = "variable", address = 0x02 },
            right = { type = "literal", value = 10 }
        },
        body = {
            {
                type = "assignment",
                target = { address = 0x02 },
                target_type = "u8",
                value = {
                    type = "binary_op",
                    op = "+",
                    left = { type = "variable", address = 0x02 },
                    right = { type = "literal", value = 5 }
                }
            }
        }
    }
}

print("Compiling AST to 6502...")
for _, node in ipairs(mock_ast) do
    codegen:generate(node)
end

print("\n--- EMITTED ASSEMBLY ---")
print(codegen:get_code())

-- Helper to split a 16-bit integer into low and high bytes
local function split_16bit(val)
    local low = val & 0xFF
    local high = (val >> 8) & 0xFF
    return string.format("%02X", low), string.format("%02X", high)
end

function CodeGen:generate(node)
    if node.type == "literal" then
        if node.inferred_type == "u16" then
            -- Return low/high pair for 16-bit literals
            local low, high = split_16bit(node.value)
            return { low = "#$" .. low, high = "#$" .. high, is_16bit = true }
        else
            return "#$" .. string.format("%02X", node.value)
        end

    elseif node.type == "variable" then
        if node.inferred_type == "u16" then
            local addr_low = node.address
            local addr_high = node.address + 1
            return { 
                low = "$" .. string.format("%02X", addr_low), 
                high = "$" .. string.format("%02X", addr_high), 
                is_16bit = true 
            }
        else
            return "$" .. string.format("%02X", node.address)
        end

    elseif node.type == "assignment" then
        local target_type = node.target_type
        
        if target_type == "u16" then
            local val_src = self:generate(node.value)
            local target_addr_low = "$" .. string.format("%02X", node.target.address)
            local target_addr_high = "$" .. string.format("%02X", node.target.address + 1)
            
            -- If value is a simple literal/variable 16-bit pair
            if type(val_src) == "table" and val_src.is_16bit then
                self:emit("LDA " .. val_src.low)
                self:emit("STA " .. target_addr_low)
                self:emit("LDA " .. val_src.high)
                self:emit("STA " .. target_addr_high)
            else
                -- If it's a binary operation, the result is already sitting in virtual registers/accumulator
                -- (We'll assume the binop handler already updated the target RAM addresses)
            end
        else
            -- Standard 8-bit assignment (as written previously)
            local val_src = self:generate(node.value)
            local target_addr = "$" .. string.format("%02X", node.target.address)
            if val_src ~= "A" then
                self:emit("LDA " .. val_src)
            end
            self:emit("STA " .. target_addr)
        end

    elseif node.type == "binary_op" and node.op == "+" then
        local left = self:generate(node.left)
        local right = self:generate(node.right)

        -- If either side is 16-bit, we must run a 16-bit addition
        if (type(left) == "table" and left.is_16bit) or (type(right) == "table" and right.is_16bit) then
            -- Normalize single 8-bit operands to a 16-bit structure if mixing types
            local L = type(left) == "table" and left or { low = left, high = "#$00" }
            local R = type(right) == "table" and right or { low = right, high = "#$00" }

            -- In a real compiler, we write directly to target or a 16-bit scratchpad register.
            -- Let's assume we are compiling: target = left + right
            local target_low = "$" .. string.format("%02X", node.target_address)
            local target_high = "$" .. string.format("%02X", node.target_address + 1)

            self:emit("LDA " .. L.low)
            self:emit("CLC")
            self:emit("ADC " .. R.low)
            self:emit("STA " .. target_low)

            self:emit("LDA " .. L.high)
            self:emit("ADC " .. R.high)
            self:emit("STA " .. target_high)
            
            return { low = target_low, high = target_high, is_16bit = true }
        else
            -- Standard 8-bit addition (as written previously)
            self:emit("LDA " .. left)
            self:emit("CLC")
            self:emit("ADC " .. right)
            return "A"
        end
    end
end

function SymbolTable.new_global_scope()
    local scope = SymbolTable.new(nil)
    
    -- Pre-populate NES Memory Mapped I/O Registers
    local hw_registers = {
        PPU_CTRL   = 0x2000,
        PPU_MASK   = 0x2001,
        PPU_STATUS = 0x2002,
        OAM_ADDR   = 0x2003,
        OAM_DATA   = 0x2004,
        PPU_SCROLL = 0x2005,
        PPU_ADDR   = 0x2006,
        PPU_DATA   = 0x2007,
        JOYPAD1    = 0x4016,
        JOYPAD2    = 0x4017,
    }
    
    for name, address in pairs(hw_registers) do
        scope.vars[name] = {
            type = "u8",
            address = address,
            is_volatile = true -- Volatile means "do not optimize away reads or writes"
        }
    end
    
    return scope
end

-- Helper to format physical addresses dynamically
local function format_address(address)
    if address < 0x100 then
        -- Zero Page: 2 hex digits
        return "$" .. string.format("%02X", address)
    else
        -- Absolute Page: 4 hex digits (little-endian output formatted for assemblers)
        return "$" .. string.format("%04X", address)
    end
end

-- Inside CodeGen:generate:
if node.type == "assignment" then
    local val_src = self:generate(node.value)
    local target_addr = format_address(node.target.address) -- Dynamic format

    if val_src ~= "A" then
        self:emit("LDA " .. val_src)
    end
    self:emit("STA " .. target_addr)
end
