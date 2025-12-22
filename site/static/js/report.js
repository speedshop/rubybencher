const { instances = [], benchmarks = [] } = window.reportConfig || {};

// D3 categorical color palette
const colorPalette = ['#4e79a7', '#f28e2c', '#e15759', '#76b7b2', '#59a14f', '#edc949', '#af7aa1', '#ff9da7', '#9c755f', '#bab0ab'];
const colors = {};
instances.forEach((inst, i) => {
  colors[inst] = colorPalette[i % colorPalette.length];
});

// Color scale for relative percentages (green = 0%, red = 300%+)
const colorScale = d3.scaleLinear()
  .domain([0, 50, 150, 300])
  .range(['#22863a', '#6a9f3d', '#d9822b', '#cb2431'])
  .clamp(true);

// Apply colors to relative percentages
document.querySelectorAll('.rel-cell[data-relative]').forEach(el => {
  const rel = parseFloat(el.dataset.relative);
  if (rel > 0) {
    el.style.color = colorScale(rel);
  } else if (el.textContent.trim() === '') {
    // Leave empty cells unstyled
  } else {
    el.style.color = '#22863a';
  }
});

// Create gradient for legend bar
const legendBar = document.getElementById('color-legend-bar');
legendBar.style.background = `linear-gradient(to right, ${[0, 50, 150, 300].map(v => colorScale(v)).join(', ')})`;

// Instance filtering state
let selectedInstances = new Set(instances);
let isFirstClick = true;

// Get all checkbox elements
const checkboxItems = document.querySelectorAll('.instance-checkbox');

// Summary chart data and elements (populated after fetch)
let summaryData = null;
let summaryLines = [];
const tooltipEl = document.getElementById('tooltip');

// Update visibility based on selected instances
function updateVisibility() {
  // Update table columns (desktop)
  document.querySelectorAll('th.instance-group').forEach(th => {
    const instance = th.textContent.trim();
    th.style.display = selectedInstances.has(instance) ? '' : 'none';
    // Also hide the 3 sub-headers below
    const row = th.closest('tr');
    const idx = Array.from(row.children).indexOf(th);
    const subHeaderRow = row.nextElementSibling;
    if (subHeaderRow) {
      // Each instance has 3 sub-headers
      const instanceIndex = instances.indexOf(instance);
      if (instanceIndex >= 0) {
        const startIdx = 1 + instanceIndex * 3; // +1 for Benchmark column
        for (let i = 0; i < 3; i++) {
          const subTh = subHeaderRow.children[startIdx + i];
          if (subTh) subTh.style.display = selectedInstances.has(instance) ? '' : 'none';
        }
      }
    }
  });

  // Update table cells
  document.querySelectorAll('td.instance-cell').forEach(td => {
    const instance = td.dataset.instance;
    td.style.display = selectedInstances.has(instance) ? '' : 'none';
  });

  // Update mobile table rows
  document.querySelectorAll('#results-table-mobile tbody tr').forEach(tr => {
    const instance = tr.dataset.instance;
    tr.style.display = selectedInstances.has(instance) ? '' : 'none';
  });

  // Update summary chart lines visibility
  summaryLines.forEach(line => {
    const inst = d3.select(line).datum().instance;
    line.style.display = selectedInstances.has(inst) ? '' : 'none';
  });

  // Sync scrollbar width after column changes
  syncScrollbarWidth();
}

// Sync checkbox visuals with selectedInstances state
function syncCheckboxes() {
  checkboxItems.forEach(item => {
    const inst = item.dataset.instance;
    const visual = item.querySelector('.checkbox-visual');
    if (selectedInstances.has(inst)) {
      item.classList.add('checked');
      visual.style.backgroundColor = colors[inst];
    } else {
      item.classList.remove('checked');
      visual.style.backgroundColor = 'white';
    }
  });
}

function handleInstanceClick(instance) {
  if (isFirstClick && selectedInstances.size === instances.length) {
    // First click when all are selected: select only this one
    selectedInstances.clear();
    selectedInstances.add(instance);
    isFirstClick = false;
  } else {
    // Toggle this instance
    if (selectedInstances.has(instance)) {
      selectedInstances.delete(instance);
    } else {
      selectedInstances.add(instance);
    }
  }

  syncCheckboxes();
  updateVisibility();
}

// Handle checkbox item clicks
checkboxItems.forEach(item => {
  const instance = item.dataset.instance;
  item.addEventListener('click', () => handleInstanceClick(instance));
});

// Select all / deselect all
document.getElementById('select-all').addEventListener('click', (e) => {
  e.preventDefault();
  selectedInstances = new Set(instances);
  isFirstClick = true;
  syncCheckboxes();
  updateVisibility();
});

document.getElementById('deselect-all').addEventListener('click', (e) => {
  e.preventDefault();
  selectedInstances.clear();
  isFirstClick = false;
  syncCheckboxes();
  updateVisibility();
});

// Table filter
const filterInput = document.getElementById('filter');
const tableRows = document.querySelectorAll('#results-table tbody tr');
filterInput.addEventListener('input', function() {
  const filter = this.value.toLowerCase();
  tableRows.forEach(row => {
    row.style.display = row.dataset.name.includes(filter) ? '' : 'none';
  });
});

// Check for benchmark URL parameter and apply filter
const urlParams = new URLSearchParams(window.location.search);
const benchmarkParam = urlParams.get('benchmark');
if (benchmarkParam) {
  filterInput.value = benchmarkParam;
  filterInput.dispatchEvent(new Event('input'));
}

// Legend highlight (all summary lines for an instance)
function highlightInstance(inst) {
  summaryLines.forEach(line => {
    const d = d3.select(line).datum();
    const isTarget = d.instance === inst;
    line.setAttribute('opacity', isTarget ? 1 : 0.1);
    line.setAttribute('stroke-width', isTarget ? 2 : 1);
  });
}

function clearInstanceHighlight() {
  summaryLines.forEach(line => {
    if (selectedInstances.has(d3.select(line).datum().instance)) {
      line.setAttribute('opacity', 1);
    }
    line.setAttribute('stroke-width', 1);
  });
}

// Summary railway chart
function renderSummaryChart(data) {
  const container = d3.select('#summary-chart');
  container.selectAll('*').remove();
  summaryLines = [];

  const width = container.node().getBoundingClientRect().width || 800;
  const height = 62;

  // Group by benchmark and calculate relative percentages
  const byBench = d3.group(data, d => d.benchmark);
  const avgData = [];
  byBench.forEach((points, benchmark) => {
    const byInstance = d3.group(points, d => d.instance);
    const instanceAvgs = [];
    byInstance.forEach((instPoints, instance) => {
      instanceAvgs.push({ instance, avg: d3.mean(instPoints, d => d.time) });
    });
    const minAvg = d3.min(instanceAvgs, d => d.avg);
    instanceAvgs.forEach(({ instance, avg }) => {
      avgData.push({
        benchmark, instance,
        avgTime: Math.round(avg),
        relativePercent: ((avg / minAvg) - 1) * 100
      });
    });
  });

  // Use 95th percentile for x-axis to exclude outliers
  const sortedRelatives = avgData.map(d => d.relativePercent).sort((a, b) => a - b);
  const p95Index = Math.floor(sortedRelatives.length * 0.95);
  const maxRelative = sortedRelatives[p95Index] || 100;

  const svg = container.append('svg')
    .attr('width', width)
    .attr('height', height)
    .attr('viewBox', `0 0 ${width} ${height}`)
    .attr('preserveAspectRatio', 'xMidYMid meet');

  const x = d3.scaleLinear().domain([0, maxRelative]).range([5, width - 5]);

  svg.append('g')
    .attr('class', 'axis')
    .attr('transform', `translate(0,${height - 8})`)
    .selectAll('text')
    .data(x.ticks(10))
    .enter().append('text')
    .attr('x', d => x(d))
    .attr('y', 7)
    .attr('text-anchor', 'middle')
    .attr('class', 'axis-label')
    .text(d => d + '%');

  svg.selectAll('.summary-benchmark-line')
    .data(avgData)
    .enter().append('line')
    .attr('class', 'summary-line summary-benchmark-line')
    .attr('x1', d => x(d.relativePercent))
    .attr('x2', d => x(d.relativePercent))
    .attr('y1', 4)
    .attr('y2', height - 12)
    .attr('stroke', d => colors[d.instance])
    .attr('stroke-width', 1)
    .attr('opacity', 1)
    .each(function() { summaryLines.push(this); })
    .on('pointerenter', function(event, d) {
      this.setAttribute('stroke-width', 2);
      tooltipEl.style.display = 'block';
      tooltipEl.style.left = (event.pageX + 10) + 'px';
      tooltipEl.style.top = (event.pageY - 10) + 'px';
      tooltipEl.innerHTML = `${d.instance}: ${d.avgTime}ms (+${d.relativePercent.toFixed(1)}%)<br><em>${d.benchmark}</em>`;
      highlightInstance(d.instance);
    })
    .on('pointerleave', function() {
      this.setAttribute('stroke-width', 1);
      tooltipEl.style.display = 'none';
      clearInstanceHighlight();
    });

  // Apply current visibility state
  summaryLines.forEach(line => {
    const inst = d3.select(line).datum().instance;
    line.style.display = selectedInstances.has(inst) ? '' : 'none';
  });
}

// Sync top scrollbar with table container
const topScrollbar = document.getElementById('top-scrollbar');
const topScrollbarInner = document.getElementById('top-scrollbar-inner');
const tableContainer = document.getElementById('table-container');
const resultsTableEl = document.getElementById('results-table');

// Set the inner div width to match the table width
function syncScrollbarWidth() {
  topScrollbarInner.style.width = resultsTableEl.scrollWidth + 'px';
}
syncScrollbarWidth();

// Sync scroll positions
let scrollingSrc = null;
topScrollbar.addEventListener('scroll', () => {
  if (scrollingSrc === 'table') { scrollingSrc = null; return; }
  scrollingSrc = 'top';
  tableContainer.scrollLeft = topScrollbar.scrollLeft;
});
tableContainer.addEventListener('scroll', () => {
  if (scrollingSrc === 'top') { scrollingSrc = null; return; }
  scrollingSrc = 'table';
  topScrollbar.scrollLeft = tableContainer.scrollLeft;
});

// Initial render
syncCheckboxes();

// Fetch data.json and render summary chart
fetch('data.json')
  .then(r => r.json())
  .then(data => {
    summaryData = data;
    renderSummaryChart(data);

    // Re-render on resize
    window.addEventListener('resize', () => {
      syncScrollbarWidth();
      renderSummaryChart(summaryData);
    });
  })
  .catch(err => console.error('Failed to load data.json:', err));
