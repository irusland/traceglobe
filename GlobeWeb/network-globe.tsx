'use client';
import worldData from './world.json';
import { useEffect, useMemo, useRef, useState, type PointerEvent } from 'react';
import {
  geoArea,
  geoDistance,
  geoGraticule10,
  geoOrthographic,
  geoPath,
} from 'd3-geo';
import type { FeatureCollection } from 'geojson';
import { Crosshair, Minus, Plus } from 'lucide-react';

type LocatedHop = { lat?: number; lon?: number; city: string; times: number[] };
const INITIAL_ROTATION: [number, number] = [45, -25];
const clampZoom = (value: number) => Math.max(0.65, Math.min(4, value));
const clampLatitude = (value: number) => Math.max(-85, Math.min(85, value));
const graticule = geoGraticule10();

export default function NetworkGlobe({
  hops,
  selected,
  onSelect,
  showRoutes = false,
}: {
  showRoutes?: boolean;
  hops: LocatedHop[];
  selected: number;
  onSelect: (index: number) => void;
}) {
  const [world, setWorld] = useState<FeatureCollection | null>(null);
  const [mapError, setMapError] = useState(false);
  const [rotation, setRotation] = useState<[number, number]>(INITIAL_ROTATION);
  const [zoom, setZoom] = useState(1);
  const [dragging, setDragging] = useState(false);
  const [size, setSize] = useState({ width: 1000, height: 500 });
  const surface = useRef<HTMLDivElement>(null);
  const pointers = useRef(new Map<number, { x: number; y: number }>());

  useEffect(() => {
    const controller = new AbortController();
    Promise.resolve(structuredClone(worldData) as FeatureCollection)
      .then((data) => {
        // D3 uses clockwise exterior rings for polygons smaller than a hemisphere.
        data.features.forEach((feature) => {
          if (geoArea(feature) <= 2 * Math.PI) return;
          const geometry = feature.geometry;
          if (geometry.type === 'Polygon')
            geometry.coordinates.forEach((ring) => ring.reverse());
          if (geometry.type === 'MultiPolygon')
            geometry.coordinates.forEach((polygon) =>
              polygon.forEach((ring) => ring.reverse()),
            );
        });
        setWorld(data);
      })
      .catch((e) => {
        if (e.name !== 'AbortError') setMapError(true);
      });
    return () => controller.abort();
  }, []);

  useEffect(() => {
    const element = surface.current;
    if (!element) return;
    const observer = new ResizeObserver((entries) => {
      const { width, height } = entries[0].contentRect;
      setSize({ width, height });
    });
    observer.observe(element);
    const wheel = (event: WheelEvent) => {
      event.preventDefault();
      const delta =
        event.deltaY *
        (event.deltaMode === 1
          ? 16
          : event.deltaMode === 2
            ? element.clientHeight
            : 1);
      setZoom((current) =>
        clampZoom(
          current * Math.exp(-Math.max(-100, Math.min(100, delta)) * 0.0025),
        ),
      );
    };
    element.addEventListener('wheel', wheel, { passive: false });
    return () => {
      observer.disconnect();
      element.removeEventListener('wheel', wheel);
    };
  }, []);

  const radius = Math.min(size.width * 0.43, size.height * 0.415) * zoom;
  const projection = useMemo(
    () =>
      geoOrthographic()
        .translate([size.width / 2, size.height / 2])
        .scale(radius)
        .rotate(rotation)
        .clipAngle(90)
        .precision(0.4),
    [size, radius, rotation],
  );
  const path = geoPath(projection);
  const located = hops
    .map((hop, index) => ({ ...hop, index }))
    .filter((h) => h.lat !== undefined && h.lon !== undefined);
  const center = projection.invert?.([size.width / 2, size.height / 2]) || [
    0, 0,
  ];

  function reset() {
    setZoom(1);
    setRotation(INITIAL_ROTATION);
  }
  function pointerDown(event: PointerEvent<SVGSVGElement>) {
    if (event.pointerType === 'mouse' && event.button !== 0) return;
    event.currentTarget.focus({ preventScroll: true });
    event.currentTarget.setPointerCapture(event.pointerId);
    pointers.current.set(event.pointerId, {
      x: event.clientX,
      y: event.clientY,
    });
    setDragging(true);
  }
  function pointerMove(event: PointerEvent<SVGSVGElement>) {
    const previous = pointers.current.get(event.pointerId);
    if (!previous) return;
    const next = { x: event.clientX, y: event.clientY };
    if (pointers.current.size === 2) {
      const other = [...pointers.current.entries()].find(
        ([id]) => id !== event.pointerId,
      )?.[1];
      if (other) {
        const oldDistance = Math.hypot(
          previous.x - other.x,
          previous.y - other.y,
        );
        const newDistance = Math.hypot(next.x - other.x, next.y - other.y);
        if (oldDistance > 5)
          setZoom((current) =>
            clampZoom((current * newDistance) / oldDistance),
          );
      }
    } else if (pointers.current.size === 1) {
      const sensitivity = 70 / Math.max(80, radius);
      setRotation(([longitude, latitude]) => [
        ((longitude + (next.x - previous.x) * sensitivity + 540) % 360) - 180,
        clampLatitude(latitude - (next.y - previous.y) * sensitivity),
      ]);
    }
    pointers.current.set(event.pointerId, next);
  }
  function pointerUp(event: PointerEvent<SVGSVGElement>) {
    pointers.current.delete(event.pointerId);
    if (event.currentTarget.hasPointerCapture(event.pointerId))
      event.currentTarget.releasePointerCapture(event.pointerId);
    setDragging(pointers.current.size > 0);
  }

  return (
    <div
      className={`map globe-map ${dragging ? 'is-dragging' : ''}`}
      ref={surface}
    >
      <div className="map-caption">
        <span className="live-dot" /> Live connections{' '}
        <span className="map-sub">
          {mapError
            ? 'Geographic boundaries unavailable'
            : 'Approximate IP locations'}
        </span>
      </div>
      {/* Interactive SVG is a keyboard-controlled application surface. */}
      {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions */}
      <svg
        className="globe-world"
        role="application"
        viewBox={`0 0 ${size.width} ${size.height}`}
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex
        tabIndex={0}
        aria-label="Interactive route globe. Drag to rotate, scroll or pinch to zoom. Arrow keys rotate, plus and minus zoom, Home resets."
        onPointerDown={pointerDown}
        onPointerMove={pointerMove}
        onPointerUp={pointerUp}
        onPointerCancel={pointerUp}
        onLostPointerCapture={(event) => {
          pointers.current.delete(event.pointerId);
          setDragging(pointers.current.size > 0);
        }}
        onKeyDown={(event) => {
          if (
            [
              'ArrowLeft',
              'ArrowRight',
              'ArrowUp',
              'ArrowDown',
              '+',
              '=',
              '-',
              'Home',
            ].includes(event.key)
          )
            event.preventDefault();
          if (event.key === 'ArrowLeft') setRotation(([x, y]) => [x - 8, y]);
          if (event.key === 'ArrowRight') setRotation(([x, y]) => [x + 8, y]);
          if (event.key === 'ArrowUp')
            setRotation(([x, y]) => [x, clampLatitude(y + 8)]);
          if (event.key === 'ArrowDown')
            setRotation(([x, y]) => [x, clampLatitude(y - 8)]);
          if (event.key === '+' || event.key === '=')
            setZoom((value) => clampZoom(value * 1.2));
          if (event.key === '-') setZoom((value) => clampZoom(value / 1.2));
          if (event.key === 'Home') reset();
        }}
      >
        <defs>
          <radialGradient id="globe-ocean" cx="34%" cy="27%">
            <stop offset="0" stopColor="#243c49" />
            <stop offset=".65" stopColor="#132630" />
            <stop offset="1" stopColor="#0c1820" />
          </radialGradient>
          <radialGradient id="globe-shade" cx="35%" cy="30%" r="70%">
            <stop offset=".4" stopColor="#02080d" stopOpacity="0" />
            <stop offset="1" stopColor="#02080d" stopOpacity=".65" />
          </radialGradient>
          <radialGradient id="globe-atmosphere">
            <stop offset=".86" stopColor="#86cdb3" stopOpacity="0" />
            <stop offset=".94" stopColor="#86cdb3" stopOpacity=".1" />
            <stop offset="1" stopColor="#86cdb3" stopOpacity="0" />
          </radialGradient>
        </defs>
        <circle
          cx={size.width / 2}
          cy={size.height / 2}
          r={radius * 1.075}
          fill="url(#globe-atmosphere)"
        />
        <path
          d={path({ type: 'Sphere' }) || ''}
          fill="url(#globe-ocean)"
          stroke="#5d8191"
          strokeOpacity=".5"
          strokeWidth="1"
        />
        <path
          d={path(graticule) || ''}
          fill="none"
          stroke="#53717e"
          strokeOpacity=".2"
          strokeWidth=".7"
        />
        {world?.features.map((feature, i) => (
          <path
            key={i}
            d={path(feature) || ''}
            fill="#314b50"
            stroke="#637d7d"
            strokeOpacity=".5"
            strokeWidth=".65"
          />
        ))}
        <circle
          cx={size.width / 2}
          cy={size.height / 2}
          r={radius}
          fill="url(#globe-shade)"
          pointerEvents="none"
        />
        {showRoutes && located.slice(1).map((hop, i) => {
          const previous = located[i];
          const d =
            path({
              type: 'LineString',
              coordinates: [
                [previous.lon!, previous.lat!],
                [hop.lon!, hop.lat!],
              ],
            }) || '';
          return (
            <g key={hop.index} pointerEvents="none">
              <path
                d={d}
                fill="none"
                stroke="#b7f57c"
                strokeWidth="7"
                opacity=".12"
              />
              <path
                d={d}
                fill="none"
                stroke="#b7f57c"
                strokeWidth="1.8"
                strokeDasharray={
                  hop.index - previous.index > 1 ? '5 5' : undefined
                }
              />
              <path
                className="route-pulse"
                d={d}
                fill="none"
                stroke="#f0ffdc"
                strokeWidth="2"
                strokeDasharray="2 32"
              />
            </g>
          );
        })}
        {located.map((hop) => {
          if (geoDistance([hop.lon!, hop.lat!], center) > Math.PI / 2 - 0.015)
            return null;
          const point = projection([hop.lon!, hop.lat!]);
          if (!point) return null;
          const [x, y] = point;
          const isSelected = selected === hop.index;
          const timing = hop.times.length
            ? (hop.times.reduce((a, b) => a + b, 0) / hop.times.length).toFixed(
                1,
              ) + ' ms'
            : showRoutes ? 'No response' : 'Active connection';
          return (
            <g
              key={hop.index}
              className="map-point"
              tabIndex={0}
              // SVG map markers need an explicit interactive role.
              // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
              role="button"
              aria-label={`Hop ${hop.index + 1}, ${hop.city}, ${timing}`}
              onPointerDown={(event) => event.stopPropagation()}
              onClick={() => onSelect(hop.index)}
              onKeyDown={(event) => {
                if (event.key === 'Enter' || event.key === ' ') {
                  event.preventDefault();
                  event.stopPropagation();
                  onSelect(hop.index);
                }
              }}
            >
              <title>{`${hop.city} · ${timing}`}</title>
              <circle
                cx={x}
                cy={y}
                r={isSelected ? 15 : 10}
                fill="#b7f57c"
                opacity={isSelected ? 0.2 : 0.06}
              />
              <circle
                cx={x}
                cy={y}
                r={isSelected ? 5 : 3.5}
                fill="#c3fa91"
                stroke="#112018"
                strokeWidth="1.5"
              />
              <text
                x={x}
                y={y - 19}
                textAnchor="middle"
                className={`globe-city-label ${isSelected || hop.index === 0 ? 'is-persistent' : 'on-hover'}`}
              >
                {hop.city.split(',')[0]}
              </text>
            </g>
          );
        })}
      </svg>
      <div className="map-controls">
        <button
          aria-label="Zoom in"
          disabled={zoom >= 4}
          onClick={() => setZoom((value) => clampZoom(value * 1.25))}
        >
          <Plus size={17} />
        </button>
        <button
          aria-label="Zoom out"
          disabled={zoom <= 0.65}
          onClick={() => setZoom((value) => clampZoom(value / 1.25))}
        >
          <Minus size={17} />
        </button>
        <button aria-label="Reset globe" onClick={reset}>
          <Crosshair size={17} />
        </button>
      </div>
      <div className="globe-zoom">{Math.round(zoom * 100)}%</div>
      <div className="globe-hint">
        Drag to rotate <span>·</span> Scroll or pinch to zoom
      </div>
      <div className="map-key">
        <span>
          <i /> Responding hop
        </span>
      </div>
      <span className="map-credit">Natural Earth</span>
    </div>
  );
}
