import { NextResponse } from 'next/server'
import { supabaseGet, verifySession } from '../../lib/auth'
import { getGoalloopRuntimeState, triggerGoalloopHeartbeat } from '../../lib/host-control'

function unauthorized() {
  return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
}

function invalid(message) {
  return NextResponse.json({ error: message }, { status: 400 })
}

async function loadWorkPayload() {
  const [runtime, scheduledTasks, taskHistory] = await Promise.all([
    getGoalloopRuntimeState(),
    supabaseGet(
      'cc_scheduled_tasks?select=id,name,cron_expr,chat_id,model,enabled,last_run,last_result,created_at,updated_at&order=created_at.desc&limit=50'
    ),
    supabaseGet(
      'cc_task_history?select=id,task_id,task_name,result,chat_id,created_at&order=created_at.desc&limit=25'
    ),
  ])

  return {
    activeGoals: runtime?.activeGoals || [],
    pausedGoals: runtime?.pausedGoals || [],
    completedGoals: runtime?.completedGoals || [],
    heartbeat: runtime?.heartbeat || { running: false, processes: [], logTail: [] },
    scheduledTasks: scheduledTasks || [],
    taskHistory: taskHistory || [],
  }
}

export async function GET(request) {
  if (!verifySession(request)) {
    return unauthorized()
  }

  try {
    return NextResponse.json(await loadWorkPayload())
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Failed to load work state'
    return NextResponse.json({ error: message }, { status: 500 })
  }
}

export async function POST(request) {
  if (!verifySession(request)) {
    return unauthorized()
  }

  const body = await request.json().catch(() => ({}))
  const action = String(body?.action || '').trim()
  if (action !== 'trigger_heartbeat') {
    return invalid('Unknown work action')
  }

  try {
    const triggerResult = await triggerGoalloopHeartbeat()
    const payload = await loadWorkPayload()
    return NextResponse.json({
      ...payload,
      message: triggerResult.stdout || triggerResult.stderr || 'GoalLoop heartbeat triggered',
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Failed to trigger GoalLoop heartbeat'
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
