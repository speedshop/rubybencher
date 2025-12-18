const { instances = [], benchmarks = [] } = window.reportConfig || {};

// D3 categorical color palette that works for any number of instances
const colorPalette = ['#4e79a7', '#f28e2c', '#e15759', '#76b7b2', '#59a14f', '#edc949', '#af7aa1', '#ff9da7', '#9c755f', '#bab0ab'];
const colors = {};
instances.forEach((inst, i) => {
  colors[inst] = colorPalette[i % colorPalette.length];
});

const tooltipEl = document.getElementById('tooltip');

// Color scale for relative percentages (green = 0%, red = 300%+)
const colorScale = d3.scaleLinear()
  .domain([0, 50, 150, 300])
  .range(['#22863a', '#6a9f3d', '#d9822b', '#cb2431'])
  .clamp(true);

// Apply colors to relative percentages (runs immediately, no data needed)
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

// Lookup maps (populated during render)
const svgMap = {};      // svgMap[benchmark] = SVG element
const dotMap = {};      // dotMap[benchmark][instance] = array of circle elements
const tableMap = {};    // tableMap[benchmark][instance] = array of td elements
let summaryLines = [];  // all summary line elements
let allDots = [];       // flat array of all dots for legend highlight
const legendItems = document.querySelectorAll('#legend [data-instance], #mobile-legend [data-instance]');

// Build tableMap from existing DOM
benchmarks.forEach(b => { tableMap[b] = {}; instances.forEach(i => { tableMap[b][i] = []; }); });
tableMap['all'] = {}; instances.forEach(i => { tableMap['all'][i] = []; });
document.querySelectorAll('td.instance-cell').forEach(cell => {
  const { benchmark, instance } = cell.dataset;
  if (tableMap[benchmark]?.[instance]) tableMap[benchmark][instance].push(cell);
});

// Beeswarm parameters
const cellWidth = 150;
const cellHeight = 62;
const cellPadding = 5;

// Create placeholder SVGs and populate svgMap
const container = d3.select('#beeswarm-matrix');
benchmarks.forEach(benchmark => {
  const svg = container.append('svg')
    .attr('class', 'benchmark-cell')
    .attr('data-benchmark', benchmark)
    .attr('data-loaded', 'false')
    .attr('width', cellWidth)
    .attr('height', cellHeight)
    .attr('viewBox', `0 0 ${cellWidth} ${cellHeight}`)
    .attr('preserveAspectRatio', 'xMidYMid meet');
  svg.append('text')
    .attr('class', 'benchmark-label')
    .attr('x', cellWidth / 2)
    .attr('y', 11)
    .text(benchmark.length > 22 ? benchmark.slice(0, 20) + '…' : benchmark);
  svgMap[benchmark] = svg.node();
  dotMap[benchmark] = {};
  instances.forEach(i => { dotMap[benchmark][i] = []; });
});

// Highlight helpers using cached maps
let currentHighlight = null;

function highlightBeeswarm(benchmark, instance) {
  const svg = svgMap[benchmark];
  if (!svg) return;
  svg.classList.add('svg-highlight');
  if (instance) {
    instances.forEach(inst => {
      const dots = dotMap[benchmark][inst];
      const isTarget = inst === instance;
      dots.forEach(dot => {
        dot.classList.toggle('dimmed', !isTarget);
        dot.classList.toggle('highlighted', isTarget);
      });
    });
  } else {
    Object.values(dotMap[benchmark]).flat().forEach(dot => dot.classList.add('highlighted'));
  }
}

function highlightTableCells(benchmark, instance) {
  const cells = tableMap[benchmark]?.[instance];
  if (cells) cells.forEach(c => c.classList.add('table-highlight'));
}

function clearHighlights() {
  if (!currentHighlight) return;
  const { benchmark, instance } = currentHighlight;
  const svg = svgMap[benchmark];
  if (svg) {
    svg.classList.remove('svg-highlight');
    Object.values(dotMap[benchmark]).flat().forEach(dot => {
      dot.classList.remove('dimmed', 'highlighted');
    });
  }
  if (instance) {
    const cells = tableMap[benchmark]?.[instance];
    if (cells) cells.forEach(c => c.classList.remove('table-highlight'));
    clearLegendHighlight();
  }
  currentHighlight = null;
  tooltipEl.style.display = 'none';
}

function highlightLegendItem(inst) {
  legendItems.forEach(span => {
    span.style.opacity = span.dataset.instance === inst ? '1' : '0.3';
    span.style.fontWeight = span.dataset.instance === inst ? '600' : 'normal';
  });
}

function clearLegendHighlight() {
  legendItems.forEach(span => {
    span.style.opacity = '1';
    span.style.fontWeight = 'normal';
  });
}

// Legend highlight (all instances across all benchmarks)
function highlightInstance(inst) {
  summaryLines.forEach(line => {
    const d = d3.select(line).datum();
    line.setAttribute('opacity', d.instance === inst ? 1 : 0.05);
    line.setAttribute('stroke-width', d.instance === inst ? 2 : 1);
  });
  allDots.forEach(dot => {
    const isTarget = dot.dataset.instance === inst;
    dot.classList.toggle('dimmed', !isTarget);
    dot.classList.toggle('highlighted', isTarget);
  });
}

function clearInstanceHighlight() {
  summaryLines.forEach(line => {
    line.setAttribute('opacity', 1);
    line.setAttribute('stroke-width', 1);
  });
  allDots.forEach(dot => {
    dot.classList.remove('dimmed', 'highlighted');
  });
}

// Color legend swatches and add event listeners
legendItems.forEach(span => {
  const inst = span.dataset.instance;
  span.querySelector('.swatch').style.background = colors[inst];
  span.addEventListener('pointerenter', () => highlightInstance(inst));
  span.addEventListener('pointerleave', clearInstanceHighlight);
});

// Table filter
const filterInput = document.getElementById('filter');
const tableRows = document.querySelectorAll('#results-table tbody tr');
const beeswarmCells = Object.values(svgMap);
filterInput.addEventListener('input', function() {
  const filter = this.value.toLowerCase();
  tableRows.forEach(row => {
    row.style.display = row.dataset.name.includes(filter) ? '' : 'none';
  });
  beeswarmCells.forEach(cell => {
    cell.style.display = cell.dataset.benchmark.toLowerCase().includes(filter) ? '' : 'none';
  });
});

// Check for benchmark URL parameter and apply filter
const urlParams = new URLSearchParams(window.location.search);
const benchmarkParam = urlParams.get('benchmark');
if (benchmarkParam) {
  filterInput.value = benchmarkParam;
  filterInput.dispatchEvent(new Event('input'));
}

// Event delegation for table
const resultsTable = document.getElementById('results-table');
resultsTable.addEventListener('pointerover', e => {
  const cell = e.target.closest('.instance-cell');
  const nameCell = e.target.closest('.benchmark-name');
  if (cell) {
    const { benchmark, instance } = cell.dataset;
    if (benchmark === 'all') {
      return;
    }
    clearHighlights();
    currentHighlight = { benchmark, instance };
    highlightTableCells(benchmark, instance);
    highlightBeeswarm(benchmark, instance);
  } else if (nameCell) {
    const benchmark = nameCell.closest('tr').dataset.benchmark;
    if (benchmark === 'all') return;
    clearHighlights();
    currentHighlight = { benchmark, instance: null };
    highlightBeeswarm(benchmark, null);
  }
});
resultsTable.addEventListener('pointerout', e => {
  const related = e.relatedTarget;
  if (!related || !resultsTable.contains(related)) {
    clearHighlights();
    clearInstanceHighlight();
  }
});

// Event delegation for beeswarm matrix
const beeswarmMatrix = document.getElementById('beeswarm-matrix');
beeswarmMatrix.addEventListener('pointerover', e => {
  const dot = e.target.closest('.dot');
  if (!dot) return;
  const benchmark = dot.dataset.benchmark;
  const instance = dot.dataset.instance;
  clearHighlights();
  currentHighlight = { benchmark, instance };
  highlightBeeswarm(benchmark, instance);
  highlightTableCells(benchmark, instance);
  highlightLegendItem(instance);
});
beeswarmMatrix.addEventListener('pointerout', e => {
  const related = e.relatedTarget;
  if (!related || !beeswarmMatrix.contains(related)) {
    clearHighlights();
  }
});

// Fetch data and render charts
let data = null;
let byBenchmark = null;

function renderBeeswarm(svg, benchmark) {
  if (svg.attr('data-loaded') === 'true') return;
  svg.attr('data-loaded', 'true');

  const benchData = byBenchmark.get(benchmark) || [];
  if (benchData.length === 0) return;

  const times = benchData.map(d => d.time);
  const xExtent = d3.extent(times);
  const xPadding = (xExtent[1] - xExtent[0]) * 0.1 || 10;
  const x = d3.scaleLinear()
    .domain([xExtent[0], xExtent[1] + xPadding])
    .range([cellPadding + 3, cellWidth - cellPadding]);

  const radius = 1;
  const minY = 14, maxY = cellHeight - 14;

  // Simple scatterplot: x from time, y random within bounds
  benchData.forEach(d => {
    d.px = x(d.time);
    d.py = minY + Math.random() * (maxY - minY);
  });

  svg.append('g')
    .attr('class', 'axis')
    .attr('transform', `translate(0,${cellHeight - 12})`)
    .selectAll('text')
    .data(x.ticks(3))
    .enter().append('text')
    .attr('x', d => x(d))
    .attr('y', 8)
    .attr('text-anchor', 'middle')
    .text(d => d >= 1000 ? (d/1000).toFixed(1) + 's' : d + 'ms');

  svg.selectAll('.dot')
    .data(benchData)
    .enter().append('circle')
    .attr('class', 'dot')
    .attr('data-instance', d => d.instance)
    .attr('data-benchmark', benchmark)
    .attr('cx', d => d.px)
    .attr('cy', d => d.py)
    .attr('r', radius)
    .attr('fill', d => colors[d.instance])
    .each(function(d) {
      dotMap[benchmark][d.instance].push(this);
      allDots.push(this);
    });

  // Trigger fade-in (double rAF ensures initial paint completes first)
  requestAnimationFrame(() => requestAnimationFrame(() => svg.node().classList.add('rendered')));
}

function renderSummaryChart() {
  const summaryContainer = d3.select('#summary-beeswarm');
  const summaryWidth = summaryContainer.node().getBoundingClientRect().width || 800;
  const summaryHeight = 62;

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

  const svg = summaryContainer.append('svg')
    .attr('width', summaryWidth)
    .attr('height', summaryHeight)
    .attr('viewBox', `0 0 ${summaryWidth} ${summaryHeight}`)
    .attr('preserveAspectRatio', 'xMidYMid meet');

  const x = d3.scaleLinear().domain([0, maxRelative]).range([5, summaryWidth - 5]);

  svg.append('g')
    .attr('class', 'axis')
    .attr('transform', `translate(0,${summaryHeight - 8})`)
    .selectAll('text')
    .data(x.ticks(10))
    .enter().append('text')
    .attr('x', d => x(d))
    .attr('y', 7)
    .attr('text-anchor', 'middle')
    .text(d => d + '%');

  svg.selectAll('.summary-benchmark-line')
    .data(avgData)
    .enter().append('line')
    .attr('class', 'summary-line summary-benchmark-line')
    .attr('x1', d => x(d.relativePercent))
    .attr('x2', d => x(d.relativePercent))
    .attr('y1', 4)
    .attr('y2', summaryHeight - 12)
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
    })
    .on('pointerleave', function() {
      this.setAttribute('stroke-width', 1);
      tooltipEl.style.display = 'none';
    });

  // Trigger fade-in (double rAF ensures initial paint completes first)
  requestAnimationFrame(() => requestAnimationFrame(() => svg.node().classList.add('rendered')));
}

// Fetch data, render summary immediately, lazy-load beeswarms
fetch('data.json')
  .then(r => r.json())
  .then(d => {
    data = d;
    byBenchmark = d3.group(data, d => d.benchmark);

    renderSummaryChart();

    const observer = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          renderBeeswarm(d3.select(entry.target), entry.target.dataset.benchmark);
          observer.unobserve(entry.target);
        }
      });
    }, { rootMargin: '100px' });

    Object.values(svgMap).forEach(cell => observer.observe(cell));
  });

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
window.addEventListener('resize', syncScrollbarWidth);

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
