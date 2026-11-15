import { useEffect, useRef, useState } from 'react'

type VM = { id: string; name: string; running: boolean }
type Page = 'create' | 'vms'

const I = (p: { d: string; size?: number }) => (
  <svg
    width={p.size ?? 20}
    height={p.size ?? 20}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="1.6"
    strokeLinecap="round"
    strokeLinejoin="round"
  >
    <path d={p.d} />
  </svg>
)
const ic = {
  menu: 'M4 6h16M4 12h16M4 18h16',
  user: 'M12 12a4 4 0 100-8 4 4 0 000 8zM4 21c0-4 4-6 8-6s8 2 8 6',
  logout: 'M9 21H5V3h4M16 17l5-5-5-5M21 12H9',
  upload: 'M12 16V4M7 9l5-5 5 5M4 20h16',
  file: 'M14 3H6v18h12V7l-4-4zM14 3v4h4',
  play: 'M7 4l13 8-13 8V4z',
  pause: 'M8 5v14M16 5v14',
  trash: 'M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3',
  edit: 'M4 20h4L19 9l-4-4L4 16v4z',
  check: 'M5 12l5 5 9-10',
  close: 'M6 6l12 12M18 6L6 18',
  server: 'M4 4h16v6H4zM4 14h16v6H4zM8 7h.01M8 17h.01',
  plus: 'M12 5v14M5 12h14',
}

const btn =
  'inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2.5 text-sm font-medium transition disabled:opacity-40 disabled:cursor-not-allowed'
const primary = `${btn} bg-indigo-500 text-white hover:bg-indigo-400`
const ghost = `${btn} border border-white/10 text-zinc-300 hover:bg-white/5`

function Login({ onLogin }: { onLogin: (n: string) => void }) {
  const [email, setEmail] = useState('')
  const [pw, setPw] = useState('')
  const field =
    'w-full rounded-lg border border-white/10 bg-zinc-950 px-3.5 py-2.5 text-sm text-zinc-100 outline-none placeholder:text-zinc-600 focus:border-indigo-400'
  return (
    <div className="flex min-h-screen items-center justify-center bg-zinc-950 p-6">
      <form
        onSubmit={(e) => {
          e.preventDefault()
          onLogin(email.split('@')[0] || 'User')
        }}
        className="w-full max-w-sm rounded-2xl border border-white/10 bg-zinc-900 p-8"
      >
        <div className="mb-6 flex h-11 w-11 items-center justify-center rounded-xl bg-indigo-500/15 text-indigo-300">
          <I d={ic.server} size={22} />
        </div>
        <h1 className="text-2xl font-semibold text-white">Welcome back</h1>
        <p className="mt-1 mb-6 text-sm text-zinc-400">Sign in to manage your virtual machines.</p>
        <label className="mb-1.5 block text-xs text-zinc-400">Email</label>
        <input className={field} type="email" required value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@example.com" />
        <label className="mt-4 mb-1.5 block text-xs text-zinc-400">Password</label>
        <input className={field} type="password" required value={pw} onChange={(e) => setPw(e.target.value)} placeholder="••••••••" />
        <button className={`${primary} mt-6 w-full`}>Log in</button>
        <p className="mt-4 text-center text-xs text-zinc-600">Demo only: any credentials work.</p>
      </form>
    </div>
  )
}

function CreateVM({ onCreate }: { onCreate: (name: string) => void }) {
  const [file, setFile] = useState<File | null>(null)
  const [state, setState] = useState<'idle' | 'creating' | 'done'>('idle')
  const [drag, setDrag] = useState(false)
  const input = useRef<HTMLInputElement>(null)

  const pick = (f?: File) => {
    if (!f) return
    if (!f.name.toLowerCase().endsWith('.zip')) return alert('Please select a .zip file.')
    setFile(f)
    setState('idle')
  }
  const create = () => {
    if (!file) return
    setState('creating')
    setTimeout(() => {
      onCreate(file.name.replace(/\.zip$/i, ''))
      setState('done')
    }, 2500)
  }
  const reset = () => {
    setFile(null)
    setState('idle')
  }

  return (
    <div className="mx-auto max-w-2xl">
      <h2 className="text-2xl font-semibold text-white">Create virtual machine</h2>
      <p className="mt-1 mb-8 text-sm text-zinc-400">
        Upload your app. AI writes a setup script and builds the VM from it.
      </p>
      <input ref={input} type="file" accept=".zip" hidden onChange={(e) => pick(e.target.files?.[0])} />
      <div
        onClick={() => state === 'idle' && input.current?.click()}
        onDragOver={(e) => {
          e.preventDefault()
          setDrag(true)
        }}
        onDragLeave={() => setDrag(false)}
        onDrop={(e) => {
          e.preventDefault()
          setDrag(false)
          if (state === 'idle') pick(e.dataTransfer.files[0])
        }}
        className={`flex h-56 cursor-pointer flex-col items-center justify-center gap-3 rounded-2xl border-2 border-dashed text-center transition ${
          drag ? 'border-indigo-400 bg-indigo-500/10' : 'border-white/15 bg-zinc-900 hover:border-white/30'
        }`}
      >
        {file ? (
          <>
            <div className="flex h-12 w-12 items-center justify-center rounded-xl bg-indigo-500/15 text-indigo-300">
              <I d={ic.file} size={24} />
            </div>
            <div className="text-sm font-medium text-zinc-100">{file.name}</div>
            <div className="text-xs text-zinc-500">{(file.size / 1024).toFixed(1)} KB</div>
          </>
        ) : (
          <>
            <div className="text-zinc-500">
              <I d={ic.upload} size={28} />
            </div>
            <div className="text-sm text-zinc-300">Upload your entire application files (.zip)</div>
            <div className="text-xs text-zinc-600">Click or drag and drop</div>
          </>
        )}
      </div>

      <div className="mt-6 flex items-center gap-3">
        {state !== 'done' && (
          <button className={primary} disabled={!file || state === 'creating'} onClick={create}>
            <I d={ic.plus} size={16} /> Create VM
          </button>
        )}
        {state === 'creating' && (
          <span className="flex items-center gap-2 text-sm text-zinc-300">
            <span className="h-4 w-4 animate-spin rounded-full border-2 border-indigo-400 border-t-transparent" />
            Creating virtual machine...
          </span>
        )}
      </div>

      {state === 'done' && (
        <div className="mt-2 flex items-center justify-between rounded-xl border border-emerald-500/30 bg-emerald-500/10 p-4">
          <span className="flex items-center gap-2 text-sm text-emerald-300">
            <I d={ic.check} size={18} /> Confirmed. "{file?.name.replace(/\.zip$/i, '')}" was added to Your VMs.
          </span>
          <button className={ghost} onClick={reset}>
            Create another
          </button>
        </div>
      )}
    </div>
  )
}

function Dashboards() {
  const [v, setV] = useState([34, 52, 12])
  useEffect(() => {
    const t = setInterval(
      () => setV((p) => p.map((x) => Math.max(3, Math.min(97, x + (Math.random() - 0.5) * 14)))),
      1200,
    )
    return () => clearInterval(t)
  }, [])
  const items = ['CPU', 'Memory', 'Network']
  return (
    <div className="grid gap-4 sm:grid-cols-3">
      {items.map((n, i) => (
        <div key={n} className="rounded-xl border border-white/10 bg-zinc-950 p-4">
          <div className="text-xs text-zinc-500">{n}</div>
          <div className="mt-1 text-2xl font-semibold text-white">{v[i].toFixed(0)}%</div>
          <div className="mt-3 h-1.5 overflow-hidden rounded-full bg-white/10">
            <div className="h-full rounded-full bg-indigo-400 transition-all duration-700" style={{ width: `${v[i]}%` }} />
          </div>
        </div>
      ))}
    </div>
  )
}

function VMs({ vms, setVms }: { vms: VM[]; setVms: (f: (p: VM[]) => VM[]) => void }) {
  const [editing, setEditing] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const upd = (id: string, patch: Partial<VM>) => setVms((p) => p.map((v) => (v.id === id ? { ...v, ...patch } : v)))
  const save = (id: string) => {
    if (draft.trim()) upd(id, { name: draft.trim() })
    setEditing(null)
  }
  const icon = 'rounded-lg p-2 text-zinc-400 hover:bg-white/10 hover:text-white'

  return (
    <div className="mx-auto max-w-4xl">
      <h2 className="text-2xl font-semibold text-white">Your VMs</h2>
      <p className="mt-1 mb-8 text-sm text-zinc-400">Rename, start, pause or delete your virtual machines.</p>
      {vms.length === 0 && (
        <div className="rounded-2xl border border-dashed border-white/15 p-12 text-center text-sm text-zinc-500">
          No virtual machines yet.
        </div>
      )}
      <div className="space-y-4">
        {vms.map((vm) => (
          <div key={vm.id} className="overflow-hidden rounded-2xl border border-white/10 bg-zinc-900">
            <div className="flex items-center gap-3 p-4">
              <span className={`h-2.5 w-2.5 rounded-full ${vm.running ? 'bg-emerald-400' : 'bg-zinc-600'}`} />
              <div className="min-w-0 flex-1">
                {editing === vm.id ? (
                  <input
                    autoFocus
                    value={draft}
                    onChange={(e) => setDraft(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') save(vm.id)
                      if (e.key === 'Escape') setEditing(null)
                    }}
                    className="w-full rounded-md border border-indigo-400 bg-zinc-950 px-2 py-1 text-sm text-white outline-none"
                  />
                ) : (
                  <div className="truncate text-sm font-medium text-zinc-100">{vm.name}</div>
                )}
                <div className="text-xs text-zinc-500">{vm.running ? 'Running' : 'Stopped'}</div>
              </div>
              {editing === vm.id ? (
                <>
                  <button className={icon} title="Save" onClick={() => save(vm.id)}><I d={ic.check} /></button>
                  <button className={icon} title="Cancel" onClick={() => setEditing(null)}><I d={ic.close} /></button>
                </>
              ) : (
                <button
                  className={icon}
                  title="Rename"
                  onClick={() => {
                    setEditing(vm.id)
                    setDraft(vm.name)
                  }}
                >
                  <I d={ic.edit} />
                </button>
              )}
              <button
                className={`${icon} ${vm.running ? 'text-amber-300' : 'text-emerald-300'}`}
                title={vm.running ? 'Pause' : 'Start'}
                onClick={() => {
                  const nextState = !vm.running
                  upd(vm.id, { running: nextState })
                  if (nextState) {
                    window.open('http://localhost:8006', '_blank')
                  }
                }}
              >
                <I d={vm.running ? ic.pause : ic.play} />
              </button>
              <button className={icon} title="Delete" onClick={() => setVms((p) => p.filter((v) => v.id !== vm.id))}>
                <I d={ic.trash} />
              </button>
            </div>
            {vm.running && (
              <div className="border-t border-white/10 bg-black/30 p-4">
                <Dashboards />
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}

export default function App() {
  const [user, setUser] = useState<string | null>(null)
  const [page, setPage] = useState<Page>('create')
  const [menu, setMenu] = useState(false)
  const [vms, setVms] = useState<VM[]>([])

  if (!user) return <Login onLogin={(n) => { setUser(n); setPage('create') }} />

  const go = (p: Page) => {
    setPage(p)
    setMenu(false)
  }
  const nav = [
    { id: 'create' as Page, label: 'Create VM', icon: ic.plus },
    { id: 'vms' as Page, label: 'Your VMs', icon: ic.server },
  ]

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-200">
      <header className="sticky top-0 z-20 flex h-16 items-center justify-between border-b border-white/10 bg-zinc-900 px-4">
        <button className="rounded-lg p-2 text-zinc-300 hover:bg-white/10" onClick={() => setMenu(true)} aria-label="Open menu">
          <I d={ic.menu} size={22} />
        </button>
        <div className="flex items-center gap-4">
          <div className="flex items-center gap-2.5">
            <span className="flex h-9 w-9 items-center justify-center rounded-full border border-white/15 text-zinc-300">
              <I d={ic.user} size={18} />
            </span>
            <span className="text-sm text-zinc-200">{user}</span>
          </div>
          <button className={ghost} onClick={() => { setUser(null); setVms([]) }}>
            <I d={ic.logout} size={16} /> Log out
          </button>
        </div>
      </header>

      <main className="p-6 md:p-10">
        {page === 'create' ? (
          <CreateVM onCreate={(name) => setVms((p) => [...p, { id: crypto.randomUUID(), name, running: false }])} />
        ) : (
          <VMs vms={vms} setVms={setVms} />
        )}
      </main>

      <div
        className={`fixed inset-0 z-30 bg-black/60 backdrop-blur-sm transition-opacity ${menu ? 'opacity-100' : 'pointer-events-none opacity-0'}`}
        onClick={() => setMenu(false)}
      />
      <aside
        className={`fixed top-0 bottom-0 left-0 z-40 w-72 border-r border-white/10 bg-zinc-900 transition-transform duration-300 ${menu ? 'translate-x-0' : '-translate-x-full'}`}
      >
        <div className="flex h-16 items-center justify-between border-b border-white/10 px-4">
          <span className="text-sm font-medium text-white">Menu</span>
          <button className="rounded-lg p-2 text-zinc-400 hover:bg-white/10" onClick={() => setMenu(false)} aria-label="Close menu">
            <I d={ic.close} />
          </button>
        </div>
        <nav className="space-y-1 p-3">
          {nav.map((n) => (
            <button
              key={n.id}
              onClick={() => go(n.id)}
              className={`flex w-full items-center gap-3 rounded-lg px-3 py-3 text-sm transition ${
                page === n.id ? 'bg-indigo-500/15 text-indigo-200' : 'text-zinc-300 hover:bg-white/5'
              }`}
            >
              <I d={n.icon} /> {n.label}
            </button>
          ))}
        </nav>
      </aside>
    </div>
  )
}
