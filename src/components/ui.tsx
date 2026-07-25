import type { ReactNode } from 'react'

export function Card({
  title,
  right,
  children,
  className = '',
  bodyClass = 'p-3',
}: {
  title?: ReactNode
  right?: ReactNode
  children: ReactNode
  className?: string
  bodyClass?: string
}) {
  return (
    <section className={`card ${className}`}>
      {title !== undefined && (
        <header className="card-head">
          <span className="label">{title}</span>
          {right}
        </header>
      )}
      <div className={bodyClass}>{children}</div>
    </section>
  )
}

/**
 * A labelled slider with a numeric readout.
 *
 * The readout is editable: dragging is right for exploring, typing is right for
 * hitting an exact number, and this app needs both.
 */
export function Slider({
  label,
  value,
  min,
  max,
  step = 1,
  unit = '',
  onChange,
  hint,
  format,
  disabled,
}: {
  label: string
  value: number
  min: number
  max: number
  step?: number
  unit?: string
  onChange: (v: number) => void
  hint?: ReactNode
  format?: (v: number) => string
  disabled?: boolean
}) {
  const shown = format ? format(value) : String(value)
  return (
    <div className={disabled ? 'opacity-50' : undefined}>
      <div className="flex items-baseline justify-between gap-2">
        <span className="label">{label}</span>
        <span className="num text-[13px] text-ink-100">
          {shown}
          {unit && <span className="text-ink-400">{unit}</span>}
        </span>
      </div>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        disabled={disabled}
        onChange={(e) => onChange(Number(e.target.value))}
        aria-label={label}
      />
      {hint && <p className="mt-0.5 text-[11px] leading-snug text-ink-500">{hint}</p>}
    </div>
  )
}

export function NumberField({
  label,
  value,
  onChange,
  min,
  max,
  step = 1,
  unit,
}: {
  label: string
  value: number
  onChange: (v: number) => void
  min?: number
  max?: number
  step?: number
  unit?: string
}) {
  return (
    <label className="block">
      <span className="label">{label}</span>
      <div className="mt-1 flex items-center gap-1">
        <input
          className="input num"
          type="number"
          value={value}
          min={min}
          max={max}
          step={step}
          onChange={(e) => {
            const n = Number(e.target.value)
            if (!Number.isNaN(n)) onChange(n)
          }}
        />
        {unit && <span className="text-[11px] text-ink-500">{unit}</span>}
      </div>
    </label>
  )
}

export function TextField({
  label,
  value,
  onChange,
  placeholder,
}: {
  label: string
  value: string
  onChange: (v: string) => void
  placeholder?: string
}) {
  return (
    <label className="block">
      <span className="label">{label}</span>
      <input
        className="input mt-1"
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
      />
    </label>
  )
}

export function Select<T extends string | number>({
  label,
  value,
  options,
  onChange,
  hint,
}: {
  label: string
  value: T
  options: { value: T; label: string }[]
  onChange: (v: T) => void
  hint?: ReactNode
}) {
  return (
    <label className="block">
      <span className="label">{label}</span>
      <select
        className="input mt-1"
        value={String(value)}
        onChange={(e) => {
          const raw = e.target.value
          const match = options.find((o) => String(o.value) === raw)
          if (match) onChange(match.value)
        }}
      >
        {options.map((o) => (
          <option key={String(o.value)} value={String(o.value)}>
            {o.label}
          </option>
        ))}
      </select>
      {hint && <p className="mt-0.5 text-[11px] leading-snug text-ink-500">{hint}</p>}
    </label>
  )
}

export function Toggle({
  label,
  checked,
  onChange,
  hint,
}: {
  label: string
  checked: boolean
  onChange: (v: boolean) => void
  hint?: ReactNode
}) {
  return (
    <label className="flex cursor-pointer items-start gap-2">
      <input
        type="checkbox"
        className="mt-0.5 shrink-0"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
      />
      <span className="min-w-0">
        <span className="block text-[13px] leading-tight text-ink-200">{label}</span>
        {hint && <span className="mt-0.5 block text-[11px] leading-snug text-ink-500">{hint}</span>}
      </span>
    </label>
  )
}

export function Segmented<T extends string | number>({
  value,
  options,
  onChange,
}: {
  value: T
  options: { value: T; label: string; title?: string }[]
  onChange: (v: T) => void
}) {
  return (
    <div className="seg">
      {options.map((o) => (
        <button
          key={String(o.value)}
          data-on={o.value === value}
          title={o.title}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  )
}

/** A metric readout. `tone` colours the value when it needs attention. */
export function Stat({
  label,
  value,
  sub,
  tone = 'neutral',
  title,
}: {
  label: string
  value: ReactNode
  sub?: ReactNode
  tone?: 'neutral' | 'good' | 'warn' | 'danger'
  title?: string
}) {
  const color = {
    neutral: 'text-ink-100',
    good: 'text-[var(--color-good)]',
    warn: 'text-[var(--color-warn)]',
    danger: 'text-[var(--color-danger)]',
  }[tone]
  return (
    <div className="min-w-0" title={title}>
      <div className="label truncate">{label}</div>
      <div className={`num mt-0.5 truncate text-[15px] leading-tight ${color}`}>{value}</div>
      {sub && <div className="mt-0.5 truncate text-[11px] text-ink-500">{sub}</div>}
    </div>
  )
}

export function Empty({ children }: { children: ReactNode }) {
  return (
    <p className="px-1 py-4 text-center text-[12px] leading-relaxed text-ink-500">
      {children}
    </p>
  )
}
