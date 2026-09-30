import React,{useState} from 'react';
import {createRoot} from 'react-dom/client';
import NetworkGlobe from './network-globe';
type Point={id:string;city:string;lat?:number;lon?:number;times:number[]};
type Snapshot={points:Point[];selected?:string;showRoutes:boolean};
let latest:Snapshot={points:[],showRoutes:false};let notify:((data:Snapshot)=>void)|undefined;
(window as any).traceglobeUpdate=(data:Snapshot)=>{latest=data;notify?.(data)};
function App(){const [data,setData]=useState(latest);notify=setData;return <NetworkGlobe hops={data.points.map(p=>({...p,lat:p.lat??undefined,lon:p.lon??undefined}))} selected={data.points.findIndex(p=>p.id===data.selected)} showRoutes={data.showRoutes} onSelect={i=>{const id=data.points[i]?.id;if(id)(window as any).webkit?.messageHandlers?.selectNode?.postMessage(id)}}/>};
createRoot(document.getElementById('root')!).render(<App/>);
