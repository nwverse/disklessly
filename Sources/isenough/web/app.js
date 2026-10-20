const out=document.querySelector('#status');
async function refresh(){try{const r=await fetch('http://127.0.0.1:47256/api/status');out.textContent=JSON.stringify(await r.json(),null,2)}catch(e){out.textContent=`Daemon unavailable: ${e.message}\nRun: isenough serve`}}
document.querySelector('#refresh').addEventListener('click',refresh);refresh();
