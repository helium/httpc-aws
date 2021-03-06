.PHONY: compile test typecheck ci

REBAR=./rebar3

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

test: compile
	$(REBAR) as test do xref, eunit, ct && $(REBAR) dialyzer

ci:
	$(REBAR) dialyzer && $(REBAR) as test do xref, eunit, ct

typecheck:
	$(REBAR) dialyzer

cover:
	$(REBAR) cover
