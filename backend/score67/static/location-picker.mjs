import {preferredLanguage, translations} from './common.mjs';
const words = await translations(preferredLanguage());
document.querySelectorAll('[data-i18n]').forEach(el => el.textContent = words[el.dataset.i18n]);
const el = id => document.getElementById(id);
let chosen = null, marker;
const map = L.map('map', {worldCopyJump:true}).setView([51.1,10.4],5);
L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {maxZoom:19,referrerPolicy:'strict-origin-when-cross-origin',attribution:'&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>'}).addTo(map).on('tileerror', () => {el('status').textContent=words['location.map_error'];});
const icon = L.divIcon({className:'', html:'<div class="location-pin"></div>',iconSize:[24,24],iconAnchor:[12,24]});
function choose(lat,lng,zoom=false) {
  if (!Number.isFinite(lat)||!Number.isFinite(lng)||Math.abs(lat)>85||Math.abs(lng)>180) return false;
  chosen={lat:Math.round(lat*1e6)/1e6,lng:Math.round(lng*1e6)/1e6};
  if (!marker) {
    marker=L.marker([lat,lng],{draggable:true,icon,title:words['location.drag']}).addTo(map);
    marker.on('dragend',()=>{const point=marker.getLatLng().wrap();choose(point.lat,point.lng);});
  } else marker.setLatLng([lat,lng]);
  if (zoom) map.setView([lat,lng],16);
  el('save').disabled=false;el('coordinates').textContent=`${chosen.lat.toFixed(6)}, ${chosen.lng.toFixed(6)}`;
  googleLink();return true;
}
function googleLink() {
  const query=el('import').value.trim() || (chosen ? `${chosen.lat},${chosen.lng}` : el('label').value.trim());
  el('google').href=`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(query||'Sportplatz')}`;
}
googleLink();el('import').oninput=googleLink;el('label').oninput=googleLink;
map.on('click',event=>{const point=event.latlng.wrap();choose(point.lat,point.lng);});
window.addEventListener('message',event=>{
  if(event.origin!==location.origin||event.source!==parent||event.data?.type!=='score67-location-init')return;
  const value=event.data.location;
  if(value){choose(value.lat,value.lng,true);el('label').value=value.label||'';el('visible').checked=value.visible===true;}
});
parent.postMessage({type:'score67-location-ready'},location.origin);
el('locate').onclick=()=>{
  if(!navigator.geolocation){el('status').textContent=words['location.geo_error'];return;}
  el('locate').disabled=true;el('status').textContent=words['location.locating'];
  navigator.geolocation.getCurrentPosition(position=>{
    el('locate').disabled=false;el('status').textContent='';choose(position.coords.latitude,position.coords.longitude,true);
  },()=>{el('locate').disabled=false;el('status').textContent=words['location.geo_error'];},{enableHighAccuracy:true,timeout:15000,maximumAge:30000});
};
el('apply').onclick=()=>{
  const value=el('import').value.trim();let pair=value.match(/^(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)$/);
  if(!pair){
    try{
      const url=new URL(value);
      if(url.protocol!=='https:'||!/(^|\.)google\.[a-z.]+$/.test(url.hostname))throw new Error('host');
      pair=decodeURIComponent(url.href).match(/!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)/);
      if(!pair)pair=(url.searchParams.get('query')||url.searchParams.get('q')||'').match(/^(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)$/);
      // @lat,lng describes the map centre, not necessarily the selected place. Do not silently import it.
    }catch{ /* Show the manual import guidance below. */ }
  }
  el('status').textContent=pair&&choose(Number(pair[1]),Number(pair[2]),true)?'':words['location.import_error'];
};
el('save').onclick=()=>{if(chosen)parent.postMessage({type:'score67-location-save',location:{...chosen,label:el('label').value.trim(),visible:el('visible').checked}},location.origin);};
el('remove').onclick=()=>parent.postMessage({type:'score67-location-save',location:null},location.origin);
