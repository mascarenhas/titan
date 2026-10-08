local temporary = require "spec.support.temporary"
local completion=require 'titan-compiler.completion'
local driver=require 'titan-compiler.driver'
local types=require 'titan-compiler.types'
local parser=require 'titan-compiler.parser'
local checker=require 'titan-compiler.checker'
local projectcache=require 'titan-compiler.projectcache'
local graphcodec=require 'titan-compiler.graphcodec'

local function prepare(source,filename)
    local caret=assert(source:find('@',1,true))-1
    source=source:sub(1,caret)..source:sub(caret+2)
    return completion.prepare(filename or './test.titan',source,caret)
end
local function analyze(source,modules)
    local prepared=assert(prepare(source))
    driver.imported={};types.registry={}
    local inputs={test=prepared.text}
    for name,text in pairs(modules or {}) do inputs[name]=text end
    local entries={}
    local loader=driver.tableloader(inputs,entries,{}, {completion=prepared.request,
        analysis_only=true,transient_caches=true,interface='source'})
    local ok,typ,errors=loader('test')
    assert.is_true(ok,tostring(typ))
    local result=assert(entries.test.completion,'no completion result')
    assert.is_true(driver.close_loader(loader))
    local names={}
    for _,row in ipairs(result.candidates) do
        names[row.name]=row
        assert.not_equal(prepared.request.name,row.name)
        for key,value in pairs(row) do
            if key=='documentation' then assert.same(value,require('titan-compiler.documentation').copy(value))
            else assert.not_equal('table',type(value)) end
        end
    end
    return names,result,prepared,errors,entries
end
local function absent(names,...)
    for _,name in ipairs({...}) do assert.is_nil(names[name],name) end
end

describe('completion analysis',function()
    local previous_imported, previous_registry
    before_each(function()
        previous_imported,previous_registry=driver.imported,types.registry
        driver.imported={};types.registry={}
    end)
    after_each(function() driver.imported=previous_imported;types.registry=previous_registry end)
    it('distinguishes current-module type members from primitive type spellings',function()
        local names=analyze('record R field:integer end type Alias=integer function f() local x:M.@ end')
        assert.truthy(names.R);assert.truthy(names.Alias)
        absent(names,'integer','float','string','boolean','value')
    end)
    it('offers keyword-named module members only through their qualified spelling',function()
        local source='function end():integer return 1 end '
        local names=analyze(source..'function f() local x=@ end')
        absent(names,'end')
        names=analyze(source..'function f() M.@ end')
        assert.truthy(names['end'])
    end)
    it('distinguishes a real hole-like binding and respects vararg lifetime',function()
        local names=analyze('function f(...:integer) local __titan_completion_hole=1 local x=@ end')
        assert.truthy(names.__titan_completion_hole);assert.truthy(names['...'])
        names=analyze('function f(...:integer) local fn=function() local x=@ end end')
        assert.is_nil(names['...'])
    end)
    it('discovers contributor imports through the parser',function()
        local deps=assert(completion.dependencies({
            {filename='one.titan',contents='local a=import "math"'},
            {filename='two.titan',contents='local p=import "other.titan"'},
        }))
        assert.same({{module_name='other',source_required=true},{module_name='titan.math',source_required=false}},deps)
    end)
    it('preserves separators and replaces the entire identifier around the caret',function()
        local p=assert(prepare('function f(r:value) r.pa@rtial end'))
        assert.matches('r.__titan_completion_hole end',p.text,1,true)
        assert.equal('pa',p.prefix)
        assert.equal(7,p.replacement_end-p.replacement_start)
        assert.equal(p.replacement_end,completion.original_byte(p.request,p.request.analysis_end_byte))
        p=assert(prepare('function f(r:value) r:@ end'))
        assert.matches('r:__titan_completion_hole end',p.text,1,true)
        assert.not_matches('__titan_completion_hole()',p.text,1,true)
    end)
    it('inserts at an exact keyword boundary without consuming the block end',function()
        local names,result,p=analyze('record R field:integer end function f(r:R) r.\n@end')
        assert.truthy(names.field);assert.equal('complete',result.quality)
        assert.equal(p.replacement_start,p.replacement_end)
        assert.matches('__titan_completion_hole end',p.text,1,true)
        names=analyze('function f(param:integer) @end')
        assert.truthy(names.param)
        assert.is_nil(prepare('foreign @function callback() end'))
    end)
    it('excludes comments and strings while recognizing import contents',function()
        for _,source in ipairs({'function f() local s="a@b" end','-- hello@\n', '--[[ @ ]]', 'local s=[=[@]=]'}) do
            assert.is_nil(prepare(source),source)
        end
        local p=assert(prepare('local m=import "foo.ba@r"'))
        assert.equal('import',p.kind);assert.equal('foo.ba',p.prefix)
        assert.equal(7,p.replacement_end-p.replacement_start)
        assert.equal('local m=import "foo.bar"',p.text)
        assert.equal('import',assert(prepare('local m=import "foo.@')).kind)
    end)
    it('replaces a complete multiword primitive leaf and retains qualifiers',function()
        local p=assert(prepare('function f(x:foreign const *unsigned lo@ng long) end'))
        assert.equal('foreign',p.kind)
        assert.equal('unsigned lo',p.prefix)
        assert.matches('foreign const *__titan_completion_hole)',p.text,1,true)
    end)
    it('captures lexical shadowing before the initializer binds its local',function()
        local names=analyze('local earlier=1 function f(param:integer) local first=1 local first=@ end')
        assert.equal('integer',names.first.detail);assert.truthy(names.param);assert.truthy(names.earlier)
        assert.truthy(names.ffi);absent(names,'__titan_completion_hole')
    end)
    it('honors the module initializer frontier and placement independent functions',function()
        local names=analyze('local earlier=1 local current=@ local later=2 function after() end')
        assert.truthy(names.earlier);assert.truthy(names.after);absent(names,'current','later')
    end)
    it('keeps loop variables outside loop bounds and inside bodies',function()
        local names=analyze('function f() for index=1,@ do end end')
        absent(names,'index')
        names=analyze('function f() for index=1,10 do local n=@ end end')
        assert.truthy(names.index)
    end)
    it('keeps repeat locals in until and protected locals out of catch',function()
        local names=analyze('function f() repeat local inside=1 until @ end')
        assert.truthy(names.inside)
        names=analyze('function f() local protected=1 catch local y=@ end')
        absent(names,'protected');assert.truthy(names.error);assert.truthy(names.traceback)
    end)
    it('captures parameters, self, enclosing locals and generic binders',function()
        local names=analyze('record R x:integer end function R:read(p:integer) local held=1 local f=function() local x=@ end end')
        assert.truthy(names.self);assert.truthy(names.p);assert.truthy(names.held)
        names=analyze('function f<|T|>(x:T) local y:@ end')
        assert.truthy(names.T);assert.equal('type',names.T.lookup_domain)
    end)
    it('specializes chained call, indexed and parenthesized receivers',function()
        for _,expr in ipairs({'get().','(get()).','items[1].'}) do
            local names=analyze('record Box<|T|> item:T end local function get():Box<|integer|> return Box.new(1) end function f(items:{Box<|integer|>}) '..expr..'@ end')
            assert.equal('integer',names.item.detail)
            absent(names,'new')
        end
    end)
    it('separates record statics, fields and bound methods including statements',function()
        local prefix='record R field:integer callback:function():integer end function R:method():integer return self.field end function R.static():integer return 1 end '
        local names=analyze(prefix..'function f(r:R) r.@ end')
        assert.truthy(names.field);assert.equal(5,names.callback.kind);absent(names,'new','method','static')
        names=analyze(prefix..'function f(r:R) r:@ end')
        assert.equal('function (): integer',names.method.detail);absent(names,'field','callback','new','static')
        names=analyze(prefix..'function f() R.@ end')
        assert.truthy(names.new);assert.truthy(names.static);absent(names,'field','method')
        names=analyze(prefix..'function f(r:R) r:@() end')
        assert.truthy(names.method)
    end)
    it('specializes static namespaces, transparent aliases and generic methods',function()
        local prefix='record Box<|T|> item:T end type IntBox=Box<|integer|> function Box:map<|U|>(f:function(T):U):U return f(self.item) end '
        local names=analyze(prefix..'function f() Box<|integer|>.@ end')
        assert.matches('integer',names.new.detail,1,true)
        names=analyze(prefix..'function f() IntBox.@ end')
        assert.matches('integer',names.new.detail,1,true)
        names=analyze(prefix..'function f(b:Box<|integer|>) b:@ end')
        assert.matches('integer',names.map.detail,1,true);assert.matches('<|U|>',names.map.detail,1,true)
    end)
    it('exposes union constructors separately and no synthetic union fields',function()
        local prefix='union U empty() payload(integer) end function U:count():integer return 1 end '
        local names=analyze(prefix..'function f() U.@ end')
        assert.truthy(names.empty);assert.truthy(names.payload);absent(names,'count')
        names=analyze(prefix..'function f(u:U) u.@ end');assert.same({},names)
        names=analyze(prefix..'function f(u:U) u:@ end');assert.truthy(names.count)
    end)
    it('uses interface declarations and constrained receiver views',function()
        local prefix='interface I number:integer function read():integer end '
        local names=analyze(prefix..'function f(i:I) i.@ end')
        assert.truthy(names.number);absent(names,'read')
        names=analyze(prefix..'function f<|T:I|>(i:T) i:@ end')
        assert.truthy(names.read);absent(names,'number')
    end)
    it('resolves actual ffi and M bindings',function()
        local names=analyze('record R field:integer end function f(ffi:R) ffi.@ end')
        assert.truthy(names.field)
        local result
        names,result=analyze('record R field:integer end local secret=1 function f() M.@ end')
        assert.truthy(names.secret);assert.truthy(names.R);absent(names,'ffi','M','L');assert.equal('dot',result.kind)
    end)
    it('preserves direct source visibility and qualified type domains',function()
        local module='local secret=1 local record Private hidden:integer end record Public visible:integer end type Alias=integer'
        local names=analyze('local m=import "other" function f() m.@ end',{other=module})
        assert.truthy(names.Public);absent(names,'secret','Private','Alias')
        names=analyze('local m=import "other.titan" function f() m.@ end',{other=module})
        assert.truthy(names.secret);assert.truthy(names.Private)
        names=analyze('local m=import "other" function f(x:m.@) end',{other=module})
        assert.truthy(names.Public);assert.truthy(names.Alias);absent(names,'secret','Private')
    end)
    it('matches ordinary foreign-function member visibility',function()
        local provider='function ordinary():integer return 1 end foreign function direct():int return 1 end'
        local names=analyze('local p=import "other.titan" foreign function f() p.@ end',{other=provider})
        assert.truthy(names.direct);absent(names,'ordinary')
        names=analyze('record R field:integer end type Alias=R foreign function f() local x=@ end')
        absent(names,'R','Alias')
    end)
    it('retains unrelated non-call statement errors as partial quality',function()
        local _,result=analyze('function f() local x=1 x local y=@ end')
        assert.equal('partial',result.quality)
    end)
    it('captures missing and partial foreign leaves in every supported type context',function()
        for _,source in ipairs({'function f(x:foreign @) end','function f():foreign @ return 1 end',
            'local type T={foreign @}','function f(x:value) local y=x as foreign @ end',
            'function f(x:value) local y=x is foreign @ end','function f(x:foreign siz@) end',
            'function f(x:foreign *@) end','function f(x:owned *@) end'}) do
            local names,result=analyze(source)
            assert.truthy(names.int,source);assert.truthy(names['unsigned long long']);assert.equal('foreign',result.kind)
            absent(names,'integer','ffi')
        end
    end)
    it('does not weaken ordinary checking of member reference statements',function()
        local ast=assert(parser.parse('./test.titan','record R field:integer end function f(r:R) r.field end'))
        local _,errors=checker.check('test',ast,'','./test.titan')
        assert.matches('only a function call may be used as a statement',table.concat(errors,'\n'),1,true)
    end)
    it('returns scalar saved facts from a detached body-free descriptor',function()
        local _,_,_,_,entries=analyze('record R field:integer end local hidden=1 function f() R.@ end')
        local entry=entries.test
        entry.type=entry.source_type;entry.source_files={entry.filename};entry.deps={};entry.source_manifest='checked'
        local compact=assert(projectcache.compact(entry))
        assert.is_nil(compact.ast);assert.truthy(compact.completion_facts)
        local payload=assert(projectcache.encode(compact))
        local restored=assert(projectcache.decode(payload))
        for _,mutate in ipairs({
            function(e) e.completion_facts=nil end,
            function(e) e.completion_facts[1].unexpected=true end,
            function(e) e.completion_facts[1].detail={} end,
            function(e) e.completion_facts[3]=nil;e.completion_facts[99]={} end,
        }) do
            local envelope=assert(graphcodec.decode(payload))
            mutate(envelope.entry)
            assert.is_nil(projectcache.decode(assert(graphcodec.encode(envelope))))
        end
        types.registry={}
        local facts=completion.describe(restored)
        local found={}
        for _,row in ipairs(facts.candidates) do found[row.name]=true end
        assert.truthy(found.hidden);assert.truthy(found.field);assert.truthy(found.new)
    end)
    it('uses the final C namespace and resolves aggregate pointer, owned and macro fields',function()
        local filename=temporary.name('.h')
        local file=assert(io.open(filename,'w'))
        file:write([[
            typedef struct Inner { int leaf; } Inner;
            typedef struct Outer { Inner inner; int plain; unsigned bits:3; } Outer;
            struct Incomplete;
            extern int global_value;
            int callable(int argument);
            enum Values { FIRST_VALUE=1, SECOND_VALUE=2, IMPLICIT_VALUE, REFERENCED_VALUE=SECOND_VALUE + 2, WIDE_VALUE=0xffffffffffffffffULL };
            typedef enum Wide { WIDE_ENUM_VALUE=0xffffffffffffffffULL } Wide;
            enum Bounds { MINIMUM=(-2147483647-1), AFTER_MINIMUM, REFERENCE_MINIMUM=MINIMUM+2 };
            #define NUMBER_VALUE 42
            #define PROJECTED inner.leaf
            #define FUNCTION_MACRO(x) ((x)+1)
        ]]);file:close()
        local ok,err=pcall(function()
            local prefix='foreign import '..string.format('%q',filename)..' '
            local names,result,_,_,entries=analyze(prefix..'local function f() ffi.@ end')
            assert.truthy(names.callable);assert.truthy(names.global_value);assert.truthy(names.NUMBER_VALUE)
            assert.truthy(names.FIRST_VALUE);assert.truthy(names.IMPLICIT_VALUE);assert.truthy(names.REFERENCED_VALUE)
            assert.truthy(names.MINIMUM);assert.truthy(names.AFTER_MINIMUM);assert.truthy(names.REFERENCE_MINIMUM)
            assert.equal('partial',result.quality)
            local entry=entries.test
            entry.type=entry.source_type;entry.source_files={entry.filename};entry.deps={};entry.source_manifest='checked'
            local restored=assert(projectcache.decode(assert(projectcache.encode(entry))))
            local saved={}
            for _,row in ipairs(completion.describe(restored).candidates) do saved[row.name]=row end
            assert.is_true(saved.AFTER_MINIMUM.available);assert.is_false(saved.WIDE_VALUE.available)
            absent(names,'WIDE_VALUE','Outer','Inner','Incomplete','FUNCTION_MACRO')
            names=analyze(prefix..'local function f(ffi:integer,x:foreign @) end')
            assert.truthy(names.Outer);assert.truthy(names.Inner);assert.truthy(names.Incomplete)
            absent(names,'callable','global_value','NUMBER_VALUE','Wide')
            names=analyze(prefix..'local function f(x:foreign *@) end')
            assert.truthy(names.Wide)
            for _,annotation in ipairs({'foreign *Outer','owned *Outer'}) do
                names=analyze(prefix..'local function f(x:'..annotation..') x.@ end')
                assert.truthy(names.inner);assert.truthy(names.plain);assert.truthy(names.bits);assert.truthy(names.PROJECTED)
                names=analyze(prefix..'local function f(x:'..annotation..') x.inner.@ end')
                assert.truthy(names.leaf);absent(names,'plain','inner')
            end
            names=analyze(prefix..'local function f() local x=foreign Outer.new() x.@ end')
            assert.truthy(names.plain)
            names=analyze(prefix..'local function f(x:foreign *Incomplete) x.@ end')
            assert.same({},names)
        end)
        os.remove(filename)
        if not ok then error(err,0) end
    end)
    it('does not consult saved graph state or disk dependencies when using detached descriptors',function()
        local filename='/tmp/titan-completion-provider.titan'
        local loader=driver.defaultloader({}, {analysis_only=true,source_roots={provider=true},
            source_overrides={provider={kind='generated',main=filename,files={filename},contents={
                [filename]='local record Hidden<|T|> field:T end local function secret():integer return 1 end'}}}})
        local ok,typ,errors=loader('provider');assert.is_true(ok,tostring(typ));assert.equal(0,#errors,table.concat(errors,'\n'))
        local payload=assert(projectcache.encode(driver.imported.provider));assert.is_true(driver.close_loader(loader))
        driver.imported={};types.registry={}
        local detached=assert(projectcache.decode(payload))
        local entries={provider=detached};types.registry=projectcache.registry(entries)
        local prepared=assert(prepare('local p=import "provider.titan" function f(x:p.Hidden<|integer|>) x.@ end'))
        local io_strategy=require('titan-compiler.io').new_sync()
        local ordinary_read=io_strategy.read_file
        function io_strategy:read_file(path)
            assert.not_matches('%.titan$',path,'completion tried to read source from disk')
            return ordinary_read(self,path)
        end
        loader=driver.defaultloader({}, {analysis_only=true,completion_closed_world=true,transient_caches=true,
            completion=prepared.request,io=io_strategy,cached_source_entries=entries,
            source_roots={test=true},source_overrides={test={kind='generated',main='./test.titan',files={'./test.titan'},contents={['./test.titan']=prepared.text}}}})
        ok,typ,errors=loader('test');assert.is_true(ok,tostring(typ))
        local result=driver.imported.test.completion
        assert.equal('field',result.candidates[1].name);assert.equal('integer',result.candidates[1].detail)
        assert.is_nil(detached.ast);assert.is_true(driver.close_loader(loader))
    end)
    it('uses only captured binaries and rejects source capability escalation and absent modules',function()
        local module=types.Module('captured',{},{});module.members[1]=types.ModuleVariable('captured','value',types.Integer(),false)
        module.members.value=module.members[1]
        local captured={captured={serialized=types.serialize(module),kind='dynamic',filename='/absent/captured.so'}}
        local loader=driver.defaultloader({}, {analysis_only=true,completion_closed_world=true,cached_binary_interfaces=captured})
        local ok,typ,errors=loader('captured');assert.is_true(ok,tostring(typ));assert.equal('Type.Integer',typ.members.value.type._tag)
        ok,typ=loader('captured',{kind='source-import'});assert.is_false(ok);assert.matches('absent from completion catalog',typ,1,true)
        ok,typ=loader('uncaptured');assert.is_false(ok);assert.matches('absent from completion catalog',typ,1,true)
        assert.is_true(driver.close_loader(loader))
    end)
    it('disables persistent native probe files within a transient resolver',function()
        local original=driver.PROBE_CACHE_DIRECTORY
        driver.PROBE_CACHE_DIRECTORY='/tmp/titan-completion-must-not-persist'
        local context=driver.new_resolver_context({analysis_only=true,transient_caches=true})
        local ok,err=pcall(function()
            local service=assert(driver.get_probe_service(context))
            assert.is_nil(service.cache_directory)
        end)
        driver.PROBE_CACHE_DIRECTORY=original
        assert.is_true(driver.close_resolver_context(context))
        if not ok then error(err,0) end
    end)
end)
