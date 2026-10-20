const $=id=>document.getElementById(id);
nero.onState(state=>{
  if(state.title){$('title').textContent=state.title;if(document.activeElement!==$('name'))$('name').value=state.title;}
  if(state.mode){$('mode').value=state.mode;$('modeLabel').textContent=state.mode;document.body.classList.toggle('review',state.mode==='Review');}
});
async function send(name,values={}){try{await nero.emit(name,values);$('status').textContent='Request sent · local demo only';}catch{$('status').textContent='Could not apply. Check the module connection.';}}
$('mode').addEventListener('change',()=>send('set_mode',{mode:$('mode').value}));
$('rename').addEventListener('click',()=>send('rename',{title:$('name').value}));
$('window').addEventListener('click',()=>send('open_window'));
