const { instances = [], benchmarks = [], summary = {} } = window.reportConfig || {};

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

  // Update summary chart
  renderSummaryChart();

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

// Summary chart
function renderSummaryChart() {
  const container = d3.select('#summary-chart');
  container.selectAll('*').remove();

  const visibleInstances = instances.filter(i => selectedInstances.has(i));

  const margin = { top: 10, right: 20, bottom: 20, left: 120 };
  const barHeight = 24;
  const minHeight = 50; // Minimum height when no instances selected
  const width = container.node().getBoundingClientRect().width || 600;
  const height = visibleInstances.length === 0
    ? minHeight
    : margin.top + margin.bottom + visibleInstances.length * barHeight;

  const svg = container.append('svg')
    .attr('width', width)
    .attr('height', height);

  // Calculate relative performance for visible instances only
  const visibleData = visibleInstances.map(inst => ({
    instance: inst,
    totalTime: summary[inst]?.total_time || 0,
    color: colors[inst]
  }));

  let maxRelative = 100; // Default for empty state
  if (visibleData.length > 0) {
    const minTime = d3.min(visibleData, d => d.totalTime);
    visibleData.forEach(d => {
      d.relative = ((d.totalTime / minTime) - 1) * 100;
    });
    maxRelative = d3.max(visibleData, d => d.relative) || 100;
  }

  const x = d3.scaleLinear()
    .domain([0, Math.max(maxRelative, 10)])
    .range([margin.left, width - margin.right]);

  const y = d3.scaleBand()
    .domain(visibleInstances)
    .range([margin.top, height - margin.bottom])
    .padding(0.2);

  // Bars (only if we have data)
  if (visibleData.length > 0) {
    svg.selectAll('.bar')
      .data(visibleData)
      .enter().append('rect')
      .attr('class', 'bar')
      .attr('x', margin.left)
      .attr('y', d => y(d.instance))
      .attr('width', d => Math.max(x(d.relative) - margin.left, 2))
      .attr('height', y.bandwidth())
      .attr('fill', d => d.color);

    // Instance labels
    svg.selectAll('.instance-label')
      .data(visibleData)
      .enter().append('text')
      .attr('class', 'chart-label')
      .attr('x', margin.left - 6)
      .attr('y', d => y(d.instance) + y.bandwidth() / 2)
      .attr('dy', '0.35em')
      .attr('text-anchor', 'end')
      .text(d => d.instance);

    // Percentage labels
    svg.selectAll('.percent-label')
      .data(visibleData)
      .enter().append('text')
      .attr('class', 'chart-label percent')
      .attr('x', d => x(d.relative) + 4)
      .attr('y', d => y(d.instance) + y.bandwidth() / 2)
      .attr('dy', '0.35em')
      .attr('text-anchor', 'start')
      .text(d => d.relative === 0 ? 'fastest' : `+${d.relative.toFixed(1)}%`);
  }

  // X axis (always drawn)
  svg.append('g')
    .attr('transform', `translate(0,${height - margin.bottom})`)
    .call(d3.axisBottom(x).ticks(5).tickFormat(d => d + '%'))
    .selectAll('text')
    .attr('class', 'axis-label');
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
window.addEventListener('resize', () => {
  syncScrollbarWidth();
  renderSummaryChart();
});

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
renderSummaryChart();
