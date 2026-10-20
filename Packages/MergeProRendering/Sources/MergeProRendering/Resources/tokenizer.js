/* App-owned immutable facade. Inputs are values, never evaluated code. */
var activeGrammar = null, activeRegistry = null, state = null, setupError = null;
function prepareGrammar(grammar, dependencies) {
  activeGrammar = null; state = null; setupError = null;
  const all = Object.fromEntries(dependencies.map(g => [g.scopeName, g]));
  all[grammar.scopeName] = grammar;
  const onigLib = {
    createOnigString(content) { return { content, dispose() {} }; },
    createOnigScanner(patterns) {
      const id = nativeCreate(patterns);
      if (id < 0) throw new Error('Native scanner compilation failed');
      return {
        findNextMatchSync(value, start, options) {
          const answer = nativeSearch(id, typeof value === 'string' ? value : value.content, start, options || 0);
          if (answer && answer.error) throw new Error('Native scanner budget or match failure');
          return answer;
        },
        dispose() { nativeDispose(id); }
      };
    }
  };
  activeRegistry = new vscodetextmate.Registry({onigLib:Promise.resolve(onigLib),loadGrammar:scope => Promise.resolve(all[scope] || null)});
  activeRegistry.loadGrammar(grammar.scopeName).then(g => { activeGrammar = g; }, () => { setupError = true; });
}
function tokenizeSourceLine(line) {
  if (!activeGrammar) throw new Error('Grammar not ready');
  const result = activeGrammar.tokenizeLine(line, state, 20);
  if (result.stoppedEarly) { state = null; throw new Error('Tokenizer budget exceeded'); }
  state = result.ruleStack;
  return result.tokens;
}
