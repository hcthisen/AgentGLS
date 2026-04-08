import { NextResponse } from 'next/server'
import { supabaseGet, verifySession } from '../../lib/auth'
import { runGoalSync, runSetupAction } from '../../lib/host-control'

const STATUS_ORDER = { active: 0, paused: 1, completed: 2 }
const PRIORITY_ORDER = { critical: 0, high: 1, medium: 2, low: 3 }

function sortGoals(goals) {
  return [...goals].sort((left, right) => {
    const statusDelta = (STATUS_ORDER[left.status] ?? 99) - (STATUS_ORDER[right.status] ?? 99)
    if (statusDelta !== 0) return statusDelta

    const priorityDelta =
      (PRIORITY_ORDER[left.priority] ?? PRIORITY_ORDER.medium) -
      (PRIORITY_ORDER[right.priority] ?? PRIORITY_ORDER.medium)
    if (priorityDelta !== 0) return priorityDelta

    return (left.title || left.slug || '').localeCompare(right.title || right.slug || '')
  })
}

function buildStats(goals) {
  const stats = {
    total: goals.length,
    active: 0,
    paused: 0,
    completed: 0,
    running: 0,
    manualApproval: 0,
  }

  for (const goal of goals) {
    if (goal.status && Object.hasOwn(stats, goal.status)) {
      stats[goal.status] += 1
    }
    if (goal.run_state === 'running') stats.running += 1
    if (goal.approval_policy === 'manual') stats.manualApproval += 1
  }

  return stats
}

async function loadGoalPayload() {
  const goals = await supabaseGet('cc_goals?select=*')
  const orderedGoals = sortGoals(goals || [])
  return {
    goals: orderedGoals,
    stats: buildStats(orderedGoals),
  }
}

export async function GET(request) {
  if (!verifySession(request)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }

  return NextResponse.json(await loadGoalPayload())
}

export async function POST(request) {
  if (!verifySession(request)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }

  const body = await request.json().catch(() => ({}))
  const action = String(body?.action || '').trim()

  if (action !== 'approve') {
    return NextResponse.json({ error: 'Unknown goals action' }, { status: 400 })
  }

  const slug = String(body?.slug || '').trim()
  if (!slug) {
    return NextResponse.json({ error: 'Goal slug is required' }, { status: 400 })
  }

  try {
    const approval = await runSetupAction('approve-goal', { slug })
    await runGoalSync()
    const payload = await loadGoalPayload()
    return NextResponse.json({
      ...payload,
      message:
        approval.stdout
          ? `Goal approved for execution: ${slug}`
          : `Goal approved for execution: ${slug}`,
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Failed to approve goal'
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
