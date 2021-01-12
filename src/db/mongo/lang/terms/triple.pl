:- module(mng_term_triple, []).

:- use_module(library('db/mongo/lang/compiler')).
:- use_module(library('db/mongo/lang/query')).

%% register query commands
:- mng_query_command(triple(_,_,_)).

%%
% triple command needs input documents from triples collection
%
mng_compiler:step_collection(triple(_,_,_),Coll) :-
	triple_db(_DB, Coll).

%%
% expose subject/predicate/object argument variables.
%
mng_compiler:step_var(
		triple(S,P,O),
		[Key, Var]) :-
	% make choicepoints for S/P/O
	member(X, [S,P,O]),
	% parse variable
	once((
		( nonvar(X), X=(_->Var) )
	;	mng_strip_type(X,_,Var)
	)),
	mng_compiler:var_key(Var, Key).

%%
% triple(S,P,O,Opts) uses $lookup to join input documents with
% the ones matching the triple pattern provided.
%
mng_compiler:step_compile(
		triple(S,P,O),
		Context,
		Pipeline) :-
	option(ask, Context),
	% get the collection name
	(	option(collection(Coll), Context)
	;	triple_db(_DB, Coll)
	),
	% extend the context
	Context0 = [
		property(P),
		collection(Coll)
	|	Context
	],
	% compute steps of the aggregate pipeline
	findall(Step,
		% filter out documents that do not match the triple pattern.
		% this is done using $match or $lookup operators.
		(	filter_(triple(S,P,O), Context0, Step)
		% conditionally needed to harmonize 'next' field
		;	set_next_(Context0, Step)
		% add additional results if P is a transitive property
		;	transitivity_(Context0, Step)
		% add additional results if P is a reflexive property
		;	reflexivity_(Context0, Step)
		% at this point 'next' field holds an array of matching documents
		% that is unwinded here.
		;	Step=['$unwind',string('$next')]
		% compute the intersection of scope so far with scope of next document
		;	scope_intersect_(Context0, Step)
		% skip documents with empty scope
		;	Step = ['$match', ['v_scope.time.since',
				['$lt', string('$v_scope.time.until')]]]
		% project new variable groundings
		;	project_(Context0, Step)
		),
		Pipeline
	).

%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% FILTERING documents based on triple pattern
%%%%%%%%%%%%%%%%%%%%%%%

%%
% first step in the pipeline needs special handling:
% it uses $match instead of $lookup as first step does not have
% any input documents to join with in lookup.
%
filter_(Triple, Context, Step) :-
	mng_triple_doc(Triple, Context, QueryDoc),
	(	memberchk(first,Context)
	->	match_(QueryDoc, Step)
	;	lookup_(QueryDoc, Context, Step)
	).

%%
match_(QueryDoc, Step) :-
	(	% find matching documents
		Step=['$match', QueryDoc]
	;	% move matching document into field *next* for next steps
		Step=['$set', [
			['next.s', string('$s')],
			['next.p', string('$p')],
			['next.o', string('$o')],
			['next.scope', string('$scope')]
		]]
	;	Step=['$set', ['v_scope', array([string('$scope')]) ]]
	).

%%
lookup_(QueryDoc, Context, Step) :-
	% lookup matching documents and store in 'next' field
    (	lookup_1(QueryDoc, Context, Step)
    % unwind the 'next' field
    ;	lookup_unwind_(Context, Step)
    ).

%% unwind $next array field.
lookup_unwind_(Context,
	['$unwind',[
		['path', string('$next')],
		['preserveNullAndEmptyArrays',bool(true)]
	]]) :-
	memberchk(ignore,Context),
	!.
lookup_unwind_(_,
	['$unwind',string('$next')]).

%% 
lookup_1(QueryDoc, Context, Lookup) :-
	% read options
	memberchk(outer_vars(QueryVars), Context),
	memberchk(collection(Coll), TripleOpts),
	triple_vars_(Context, TripleVars),
	% find all joins with input documents
	findall([Field_j,Value_j],
		(	member([Field_j,Value_j], TripleVars),
			member([Field_j,_], QueryVars)
		),
		Joins),
	% pass input document value to lookup
	findall([Let_key,string(Let_val)],
		(	member([Let_key,_],Joins),
			atom_concat('$',Let_key,Let_val)
		),
		LetDoc),
	% perform the join operation (equals the input document value)
	findall(['$eq', array([string(Match_key),string(Match_val)])],
		% { $eq: [ "$s",  "$$R" ] },
		(	member([Join_var,Join_field],Joins),
			atom_concat('$',Join_field,Match_key),
			atom_concat('$$',Join_var,Match_val)
		),
		MatchDoc),
	%
	Match=['$match', [['$expr', ['$and', array(MatchDoc)]] | QueryDoc ]],
	(	member(limit(Limit),TripleOpts)
	->	Pipeline=[Match,['$limit',int(Limit)]]
	;	Pipeline=[Match]
	),
	% finally compose the lookup document
	Lookup=['$lookup', [
		['from',string(Coll)],
		% create a field "next" with all matching documents
		['as',string('next')],
		% make fields from input document accessible in pipeline
		['let',LetDoc],
		% get matching documents
		['pipeline', array(Pipeline)]
	]].


%%
set_next_(Context, Step) :-
	%% this step is used to harmonize documents
	\+ memberchk(transitive,Context),
	(	% assign *start* field in case of reflexive property
		(	memberchk(reflexive,Context),
			Step=['$set', ['start', string('$next')]]
		)
	;	% transform next into single-element array
		Step=['$set', ['next', array([string('$next')])]]
	).

%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% PROPERTY SEMANTICS
%%%%%%%%%%%%%%%%%%%%%%%

%%
transitivity_(Context, Step) :-
	% read options
	memberchk(transitive, Context),
	memberchk(collection(Coll), Context),
	memberchk(property(Property), Context),
	% yield steps
	(	Step=['$graphLookup', [
			['from',string(Coll)],
			['startWith',string('$next.o')],
			['connectFromField',string('o')],
			['connectToField',string('s')],
			['as',string('paths')],
			['restrictSearchWithMatch',['p*',string(Property)]]
		]]
	;	Step=['$addFields', ['paths', ['$concatArrays', array([
			string('$paths'),
			array([string('$next')])
		])]]]
	;	Step=['$set', ['start', string('$next')]]
	;	Step=['$set', ['next', string('$paths')]]
	).

%%
% FIXME: this creates redundant results for the case of graph queries
%        that receive multiple documents with the same subject as input.
%        not sure how we can avoid the duplicates here...
reflexivity_(Context, Step) :-
	memberchk(reflexive,Context),
	Step=['$set', ['next', ['$concatArrays',
		array([string('$next'), array([[
			['s',string('$start.s')],
			['p',string('$start.p')],
			['o',string('$start.s')],
			['scope',string('$start.scope')]
		]])])
	]]].


%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% SCOPE INTERSECTION
%%%%%%%%%%%%%%%%%%%%%%%

%% 
scope_intersect_(Context,
		['$set', ['v_scope', Doc]]) :-
	% intersect old and new scope
	Intersect = [
		['time.since', ['$max', array([string('$v_scope.time.since'),
		                               string('$next.scope.time.since')])]],
		['time.until', ['$min', array([string('$v_scope.time.until'),
		                               string('$next.scope.time.until')])]]
	],
	(	memberchk(ignore,Context)
	->	Doc = ['$cond', array([
			['$not', array([string('$next.scope')]) ],
			string('$v_scope'),
			Intersect
		])]
	;	Doc = Intersect
	).

%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% PROJECTION
%%%%%%%%%%%%%%%%%%%%%%%

project_(Context, ['$project', ProjectDoc]) :-
	% read options
	memberchk(outer_vars(QueryVars), Context),
	triple_vars_(Context, TripleVars),
	% 
	findall([Pr_Key,Pr_Value],(
		% copy scope
		(	Pr_Key='v_scope',
			Pr_Value=string('$v_scope')
		)
		% copy value of var e.g. { 'S': '$S' }
	;	(	member([Pr_Key,_], QueryVars),
			atom_concat('$',Pr_Key,Pr_Value0),
			Pr_Value=string(Pr_Value0)
		)
		% set new value of var e.g. { 'S': '$next.s' }
	;	(	member([Pr_Key, Field],TripleVars),
			\+ member([Pr_Key,_], QueryVars),
			project_1(Context, Field, Pr_Value)
		)
	), ProjectDoc).

%% project a grounded field.
project_1(Context, Field,
		['$cond',array([
			['$not', array([string(Pr_Value)]) ],
			% HACK: REMOVE creates problems in next project step,
			% so rather choose some dump value.
			string('null'),
			%string('$$REMOVE'),
			string(Pr_Value)
		])]) :-
	memberchk(ignore,Context),
	!,
	atom_concat('$next.',Field,Pr_Value).
project_1(_,Field,string(Pr_Value)) :-
	!,
	atom_concat('$next.',Field,Pr_Value).

%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% helper
%%%%%%%%%%%%%%%%%%%%%%%

triple_vars_(Contex, [
		[S_key,s],
		[P_key,p],
		[O_key,o]]) :-
	memberchk(step_vars([
		[S_key,_],
		[P_key,_],
		[O_key,_]]), Contex).
