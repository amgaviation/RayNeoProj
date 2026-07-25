import { useState } from 'react'
import { useStore, useWorkspace } from '../lib/store'
import { Card } from './ui'

export function WorkspacePicker() {
  const profile = useStore((s) => s.profile)
  const active = useWorkspace()
  const select = useStore((s) => s.selectWorkspace)
  const add = useStore((s) => s.addWorkspace)
  const rename = useStore((s) => s.renameWorkspace)
  const remove = useStore((s) => s.deleteWorkspace)
  const duplicate = useStore((s) => s.duplicateWorkspace)
  const [editing, setEditing] = useState<string>()

  return (
    <Card
      title="Workspaces"
      right={
        <button className="btn btn-sm" onClick={() => add()}>
          + New
        </button>
      }
      bodyClass="p-2"
    >
      <div className="space-y-1">
        {profile.workspaces.map((w) => {
          const isActive = w.id === active.id
          return (
            <div
              key={w.id}
              className={`rounded-md px-2 py-1.5 transition-colors ${
                isActive ? 'bg-ink-700' : 'hover:bg-ink-800'
              }`}
            >
              <div className="flex items-center gap-1.5">
                {editing === w.id ? (
                  <input
                    autoFocus
                    className="input px-1.5 py-0.5 text-[13px]"
                    defaultValue={w.name}
                    onBlur={(e) => {
                      rename(w.id, e.target.value || w.name)
                      setEditing(undefined)
                    }}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') e.currentTarget.blur()
                      if (e.key === 'Escape') setEditing(undefined)
                    }}
                  />
                ) : (
                  <button
                    className="min-w-0 flex-1 text-left"
                    onClick={() => select(w.id)}
                    onDoubleClick={() => setEditing(w.id)}
                  >
                    <span
                      className={`block truncate text-[13px] leading-tight ${
                        isActive ? 'text-ink-100' : 'text-ink-300'
                      }`}
                    >
                      {w.name}
                    </span>
                    <span className="block truncate text-[10.5px] text-ink-500">
                      {w.panels.length} panels · {w.views.length} views
                    </span>
                  </button>
                )}
                <button
                  className="btn btn-sm btn-ghost"
                  onClick={() => duplicate(w.id)}
                  title="Duplicate this workspace"
                >
                  ⧉
                </button>
                <button
                  className="btn btn-sm btn-ghost"
                  onClick={() => remove(w.id)}
                  disabled={profile.workspaces.length <= 1}
                  title={
                    profile.workspaces.length <= 1
                      ? 'Keep at least one workspace'
                      : 'Delete this workspace'
                  }
                >
                  ✕
                </button>
              </div>
              {isActive && w.description && (
                <p className="mt-1 text-[11px] leading-snug text-ink-500">{w.description}</p>
              )}
            </div>
          )
        })}
      </div>
      <p className="mt-1.5 px-1 text-[10.5px] text-ink-600">
        Double-click a name to rename it.
      </p>
    </Card>
  )
}
