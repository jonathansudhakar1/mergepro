// Run from the repository root. Reference argument: unpacked vscode-oniguruma 2.0.1 package.
const fs=require('fs'),path=require('path');
const reference=process.argv[2];if(!reference)throw Error('Pass the unpacked pinned vscode-oniguruma 2.0.1 package path');
const tm=require(path.resolve('Packages/MergeProRendering/Sources/MergeProRendering/Resources/vscode-textmate.js'));
const onig=require(path.resolve(reference,'release/main.js'));
(async()=>{
 await onig.loadWASM(fs.readFileSync(path.resolve(reference,'release/onig.wasm')).buffer);
 const inputs=JSON.parse(fs.readFileSync('Packages/MergeProRendering/Tests/MergeProRenderingTests/Fixtures/conformance-input.json'));
 for(const test of inputs){
  const all=Object.fromEntries([test.grammar,...test.dependencies].map(g=>[g.scopeName,g]));
  const registry=new tm.Registry({onigLib:Promise.resolve(onig),loadGrammar:scope=>Promise.resolve(all[scope]||null)});
  const grammar=await registry.loadGrammar(test.grammar.scopeName);let state=null,offset=0;test.expected=[];
  for(const line of test.source.split('\n')){
   const value=grammar.tokenizeLine(line,state,20);if(value.stoppedEarly)throw Error('reference budget');state=value.ruleStack;
   for(const token of value.tokens){const end=Math.min(token.endIndex,line.length);if(end>token.startIndex)test.expected.push({location:offset+token.startIndex,length:end-token.startIndex,scopes:token.scopes});}
   offset+=line.length+1;
  }
  registry.dispose();
 }
 fs.writeFileSync('Packages/MergeProRendering/Tests/MergeProRenderingTests/Fixtures/conformance.json',JSON.stringify(inputs,null,2)+'\n');
})().catch(error=>{console.error(error);process.exit(1)});
