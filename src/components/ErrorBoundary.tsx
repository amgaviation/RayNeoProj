import { Component, type ErrorInfo, type ReactNode } from 'react'

/**
 * Contains a render failure to one pane.
 *
 * Defence in depth around the 3D preview. `SceneView` already handles the
 * predictable case — no WebGL context — but anything else three.js throws during
 * mount would otherwise propagate to the root and unmount the whole app, so a
 * graphics problem would look like a completely blank window.
 *
 * The rest of this app is SVG and arithmetic: the previews' geometry, the optics
 * analysis and every export work with no GPU whatsoever. Losing one pane should
 * never cost the user the other nine tenths of the tool.
 */
interface Props {
  children: ReactNode
  /** Shown in the fallback so the user knows which part failed. */
  label: string
}

interface State {
  error?: Error
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = {}

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Keep it in the console for anyone debugging a real failure.
    console.error(`[${this.props.label}] render failed`, error, info.componentStack)
  }

  render() {
    const { error } = this.state
    if (!error) return this.props.children

    return (
      <div className="grid h-full w-full place-items-center bg-ink-950 p-6">
        <div className="max-w-sm text-center">
          <p className="text-[13px] text-ink-200">{this.props.label} could not load</p>
          <p className="mt-1.5 text-[11.5px] leading-relaxed text-ink-500">
            The rest of the app is unaffected — layout, analysis and exports do not
            depend on this pane.
          </p>
          <code className="num mt-2 block break-words text-[10.5px] text-ink-600">
            {error.message}
          </code>
          <button className="btn btn-sm mt-3" onClick={() => this.setState({})}>
            Try again
          </button>
        </div>
      </div>
    )
  }
}
