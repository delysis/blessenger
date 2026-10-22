import { loadBlessengerGemma, gemmaModel } from './blessenger-gemma.mjs';
const precision = new URL(location.href).searchParams.get('precision') === 'fp16' ? 'fp16' : 'fp32';
const { modelID, modelRevision } = gemmaModel(precision);
const status=document.querySelector('#status'),run=document.querySelector('#run');
run.onclick=async()=>{
 run.disabled=true;let runtime;const results=[];
 try{
  runtime=await loadBlessengerGemma(p=>status.textContent=p.text,precision);
  const {engine}=runtime;

  for(const prompt of ['Reply with exactly: Hello.','Count slowly from one to one hundred.','Reply with exactly: Ready.']){
   const start=performance.now();let first=null,text='',cancelled=false;
   const stream=await engine.chat.completions.create({messages:[{role:'user',content:prompt}],temperature:1,max_tokens:48,stream:true});
   for await(const chunk of stream){
    const delta=chunk.choices[0]?.delta?.content??'';
    if(delta&&first===null)first=performance.now()-start;
    text+=delta;
    if(results.length===1&&text.length>5&&!cancelled){engine.interruptGenerate();cancelled=true;}
   }
   if(!text.trim())throw Error('Empty E2B response');
   results.push({prompt,text,firstTextMs:first,totalMs:performance.now()-start,cancelled});
   await engine.resetChat();
  }
  const pcm=new Float32Array(await (await fetch('./clinical-age.f32')).arrayBuffer());
  for(const instruction of ['', "Repeat the client's age from the recording. Only state the age.", 'Transcribe this recording exactly.']){
   await engine.resetChat();
   const audioStart=performance.now();
   const content=[{type:'input_audio',input_audio:{format:'pcm_f32',sample_rate:16000,data:pcm}}];
   if(instruction)content.push({type:'text',text:instruction});
   const audio=await engine.chat.completions.create({messages:[{role:'user',content}],temperature:1,seed:42,max_tokens:96});
   const audioText=audio.choices[0]?.message?.content??'';
   results.push({audioFixture:'clinical-age.f32',instruction,text:audioText,totalMs:performance.now()-audioStart,ageCorrect:/\b(?:forty|40)\b/i.test(audioText)});
  }
  status.textContent=JSON.stringify({passed:results.filter(x=>x.audioFixture).every(x=>x.ageCorrect),modelID,modelRevision,temperature:1,results,externalNetworkBlocked:document.querySelector('meta[http-equiv]')!==null,scope:'Browser worker text and audio generation, cancellation and cache reload; no iPhone or disconnected PWA acceptance'},null,2);
 }catch(error){status.textContent=JSON.stringify({passed:false,error:String(error),stack:error.stack,results},null,2);}
 finally{await runtime?.dispose();run.disabled=false;}
};
