module ApplicationHelper
  def status_badge_class(status)
    case status
    when 'running'
      'inline-flex px-2 text-xs font-semibold rounded-full bg-yellow-100 text-yellow-800'
    when 'completed'
      'inline-flex px-2 text-xs font-semibold rounded-full bg-green-100 text-green-800'
    when 'cancelled'
      'inline-flex px-2 text-xs font-semibold rounded-full bg-red-100 text-red-800'
    else
      'inline-flex px-2 text-xs font-semibold rounded-full bg-gray-100 text-gray-800'
    end
  end

  def task_status_badge_class(status)
    case status
    when 'pending'
      'px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-gray-100 text-gray-800'
    when 'claimed'
      'px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-blue-100 text-blue-800'
    when 'running'
      'px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-yellow-100 text-yellow-800'
    when 'completed'
      'px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-green-100 text-green-800'
    when 'failed'
      'px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-red-100 text-red-800'
    else
      'px-2 inline-flex text-xs leading-5 font-semibold rounded-full bg-gray-100 text-gray-800'
    end
  end
end
