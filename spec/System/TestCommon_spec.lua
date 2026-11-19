describe("Common", function()
	describe("Class creation and use", function()
		it("produces error when parent constructors are not called", function()
			local ParentClass = newClass("ConstructorTestParentClass")
			function ParentClass:ConstructorTestParentClass()
				return self
			end
			local ChildClass = newClass("ConstructorTestProblemChild", "ConstructorTestParentClass")
			function ChildClass:ConstructorTestProblemChild()
				-- Intentionally does not call self:ConstructorTestParentClass()
				return self
			end
			common.classes.ConstructorTestParent = ParentClass
			common.classes.ConstructorTestProblemChild = ChildClass

			assert.has_error(function()
				new("ConstructorTestProblemChild"):ConstructorTestProblemChild()
			end, "Parent class 'ConstructorTestParentClass' of class 'ConstructorTestProblemChild' must be initialised")
			common.classes.ConstructorTestParent = nil
			common.classes.ConstructorTestProblemChild = nil
		end)
		it("produces an error if additional arguments are passed", function()
			local StupidClass = newClass("NewAbuse")
			function StupidClass:NewAbuse(someParam)
				return self
			end

			common.classes.NewAbuse = StupidClass

			assert.has_no.errors(function()
				local newObj = new("NewAbuse"):NewAbuse("fish")
			end)
			assert.has_error(function()
				local newObj = new("NewAbuse", "look I'm using the old syntax")
			end)
		end)
		it("produces an error if it calls a parent class without giving it self", function()
			local ParentClass = newClass("ConstructorTestParentClass")
			function ParentClass:ConstructorTestParentClass()
				return self
			end

			local ChildClass = newClass("ConstructorTestProblemChild", "ConstructorTestParentClass")
			function ChildClass:ConstructorTestProblemChild()
				self.ConstructorTestParentClass()
				return self
			end

			common.classes.ConstructorTestParent = ParentClass
			common.classes.ConstructorTestProblemChild = ChildClass

			assert.has_error(function()
				new("ConstructorTestProblemChild"):ConstructorTestProblemChild()
			end)
			common.classes.ConstructorTestParent = nil
			common.classes.ConstructorTestProblemChild = nil
		end)
		it("produces an error if its constructor doesn't return the object", function()
			local StupidClass = newClass("StupidClass")
			function StupidClass:StupidClass()
			end

			common.classes.StupidClass = StupidClass

			assert.has_error(function()
				new("StupidClass"):StupidClass()
			end, "Class StupidClass constructor did not return a value")
		end)
		-- disabled for performance reasons for now
		-- it("produces an error if its constructor has not been called", function()
		-- 	local StupidClass = newClass("StupidClass")
		-- 	function StupidClass:StupidClass()
		-- 		return self
		-- 	end

		-- 	function StupidClass:Clear()
		-- 	end

		-- 	common.classes.StupidClass = StupidClass

		-- 	assert.has_error(function()
		-- 		local object = new("StupidClass")
		-- 		return object.lines
		-- 	end)
		-- 	assert.has_error(function()
		-- 		local object = new("StupidClass")
		-- 		object:Clear()
		-- 	end)
		-- 	assert.has_no.errors(function()
		-- 		local object = new("StupidClass"):StupidClass()
		-- 		local x = object.lines
		-- 		object:Clear()
		-- 	end)
		-- 	common.classes.StupidClass = nil
		-- end)
	end)
	describe("Hot-path shortcuts", function()
		it("getHashFromString equals sha1 before, while and after the bounded cache is filled", function()
			local text = "Time-Lost Diamond some item text"
			assert.are.equals(common.sha1(text), getHashFromString(text))
			assert.are.equals(common.sha1(text), getHashFromString(text))
			for i = 1, 5000 do
				getHashFromString("filler " .. i)
			end
			assert.are.equals(common.sha1(text), getHashFromString(text))
			assert.are.equals(common.sha1("filler 4999"), getHashFromString("filler 4999"))
		end)
		it("MatchKeywordFlags and AND64 keep their results with the zero shortcuts", function()
			-- the general rule as it was before the shortcut
			local function reference(keywordFlags, modKeywordFlags)
				local mask = NOT64(KeywordFlag.MatchAll)
				local modMasked = AND64(modKeywordFlags, mask)
				local keywordMasked = AND64(keywordFlags, mask)
				if AND64(modKeywordFlags, KeywordFlag.MatchAll) ~= 0 then
					return AND64(keywordMasked, modMasked) == modMasked
				end
				return modMasked == 0 or AND64(keywordMasked, modMasked) ~= 0
			end
			local values = { 0, KeywordFlag.Hit, KeywordFlag.Spell, KeywordFlag.Hit + KeywordFlag.Spell, KeywordFlag.Fire + KeywordFlag.MatchAll,
				KeywordFlag.Hit + KeywordFlag.Spell + KeywordFlag.MatchAll, KeywordFlag.MatchAll, 0x1FFFFFFFFFFFFF }
			for _, keywordFlags in ipairs(values) do
				for _, modKeywordFlags in ipairs(values) do
					assert.are.equals(reference(keywordFlags, modKeywordFlags), MatchKeywordFlags(keywordFlags, modKeywordFlags))
				end
				assert.are.equals(0, AND64(0, keywordFlags))
				assert.are.equals(0, AND64(keywordFlags, 0))
			end
		end)
	end)
end)
